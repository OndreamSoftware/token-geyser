pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "./IStaking.sol";
import "./TokenPool.sol";

/**
 * @title Continuous Vesting Token Distribution
 * @dev A smart-contract based mechanism to distribute tokens over time, inspired loosely by
 *      Compound and Uniswap.
 *
 *      Distribution tokens are added to a locked pool in the contract and become unlocked over time
 *      according to a once-configurable unlock schedule. Once unlocked, they are available to be
 *      claimed by users.
 *
 *      A user may deposit tokens to accrue ownership share over the unlocked pool. This owner share
 *      is a function of the number of tokens deposited as well as the length of time deposited.
 *      Specifically, a user's share of the currently-unlocked pool equals their "deposit-seconds"
 *      divided by the global "deposit-seconds". This aligns the new token distribution with long
 *      term supporters of the project, addressing one of the major drawbacks of simple airdrops.
 *
 *      More background and motivation available at:
 *      https://github.com/ampleforth/RFCs/blob/master/RFCs/rfc-1.md
 */
contract ContVestTokenDist is IStaking, Ownable {
    using SafeMath for uint256;

    event Staked(address indexed user, uint256 amount, uint256 total, bytes data);
    event Unstaked(address indexed user, uint256 amount, uint256 total, bytes data);
    event TokensClaimed(address indexed user, uint256 amount);
    event TokensLocked(uint256 amount, uint256 durationSec, uint256 total);
    event TokensUnlocked(uint256 amount, uint256 total);

    TokenPool private _stakingPool;
    TokenPool private _unlockedPool;
    TokenPool private _lockedPool;

    //
    // Global accounting state
    //
    uint256 private _totalStakingShares = 0;
    uint256 private _totalStakingShareSeconds = 0;
    uint256 private _lastAccountingTimestampSec = 0;
    uint256 private _totalLockedShares = 0;
    uint256 private _maxUnlockSchedules = 0;

    //
    // User accounting state
    //
    // Represents a single stake for a user. A user may have multiple.
    struct Stake {
        uint256 stakingShares;
        uint256 timestampSec;
    }

    // Caches aggregated values from the User->Stake[] map to save computation.
    struct UserTotals {
        uint256 stakingShares;
        uint256 stakingShareSeconds;
        uint256 lastAccountingTimestampSec;
    }

    // Aggregated staking values per user
    mapping(address => UserTotals) private _userTotals;

    // The collection of stakes for each user. Ordered by timestamp, earliest to latest.
    mapping(address => Stake[]) private _userStakes;

    //
    // Locked/Unlocked Accounting state
    //
    struct UnlockSchedule {
        uint256 initialLockedShares;
        uint256 lastUnlockTimestampSec;
        uint256 endAtSec;
        uint256 durationSec;
    }

    UnlockSchedule[] public unlockSchedules;

    /**
     * @param stakingToken The token users deposit as stake.
     * @param distributionToken The token users receive as they unstake.
     * @param maxUnlockSchedules Max number of unlock stages, to guard against hitting gas limit.
     */
    constructor(IERC20 stakingToken, IERC20 distributionToken, uint256 maxUnlockSchedules) public {
        _stakingPool = new TokenPool(stakingToken);
        _unlockedPool = new TokenPool(distributionToken);
        _lockedPool = new TokenPool(distributionToken);


        _maxUnlockSchedules = maxUnlockSchedules;
    }

    /**
     * @return The token users deposit as stake.
     */
    function getStakingToken() public view returns (IERC20) {
        return _stakingPool.getToken();
    }

    /**
     * @return The token users receive as they unstake.
     */
    function getDistributionToken() public view returns (IERC20) {
        assert(_unlockedPool.getToken() == _lockedPool.getToken());
        return _unlockedPool.getToken();
    }

    /**
     * @dev Transfers amount of deposit tokens from the user.
     * @param amount Number of deposit tokens to stake.
     * @param data Not used.
     */
    function stake(uint256 amount, bytes data) external {
        _stakeFor(msg.sender, msg.sender, amount);
    }

    /**
     * @dev Transfers amount of deposit tokens from the caller on behalf of user.
     * @param user User address who gains credit for this stake operation.
     * @param amount Number of deposit tokens to stake.
     * @param data Not used.
     */
    function stakeFor(address user, uint256 amount, bytes data) external {
        _stakeFor(msg.sender, user, amount);
    }

    /**
     * @dev Private implementation of staking methods.
     * @param staker User address who deposits tokens to stake.
     * @param beneficiary User address who gains credit for this stake operation.
     * @param amount Number of deposit tokens to stake.
     */
    function _stakeFor(address staker, address beneficiary, uint256 amount) private {
        require(amount > 0);

        updateAccounting();

        // 1. User Accounting
        // TODO: If we start with 1 share = 1 token, will we hit rounding errors in the future?
        uint256 mintedStakingShares = (totalStaked() > 0)
            ? _totalStakingShares.mul(amount).div(totalStaked())
            : amount;

        UserTotals storage totals = _userTotals[beneficiary];
        totals.stakingShares = totals.stakingShares.add(mintedStakingShares);
        totals.lastAccountingTimestampSec = now;

        Stake memory newStake = Stake(mintedStakingShares, now);
        _userStakes[beneficiary].push(newStake);

        // 2. Global Accounting
        _totalStakingShares = _totalStakingShares.add(mintedStakingShares);
        // Already set in updateAccounting()
        // _lastAccountingTimestampSec = now;

        // interactions
        require(_stakingPool.getToken().transferFrom(staker, address(_stakingPool), amount));

        emit Staked(beneficiary, amount, totalStakedFor(beneficiary), "");
    }

    /**
     * @dev Unstakes a certain amount of previously deposited tokens. User also receives their
     * alotted number of distribution tokens.
     * @param amount Number of deposit tokens to unstake / withdraw.
     * @param data Not used.
     */
    function unstake(uint256 amount, bytes data) external {
        updateAccounting();

        // checks
        require(amount > 0);
        uint256 userStakedAmpl = totalStakedFor(msg.sender);
        require(userStakedAmpl >= amount);

        // 1. User Accounting
        UserTotals memory totals = _userTotals[msg.sender];
        Stake[] storage accountStakes = _userStakes[msg.sender];
        uint256 stakingSharesToBurn = _totalStakingShares.mul(amount).div(totalStaked());

        // User wants to burn the fewest stakingShareSeconds for their AMPLs, so redeem from most
        // recent stakes and go backwards in time.
        uint256 stakingShareSecondsToBurn = 0;
        uint256 sharesLeftToBurn = stakingSharesToBurn;
        while (sharesLeftToBurn > 0) {
            Stake memory lastStake = accountStakes[accountStakes.length - 1];
            if (lastStake.stakingShares <= sharesLeftToBurn) {
                // fully redeem a past stake
                stakingShareSecondsToBurn = stakingShareSecondsToBurn
                    .add(lastStake.stakingShares.mul(now.sub(lastStake.timestampSec)));
                accountStakes.length--;
                sharesLeftToBurn = sharesLeftToBurn.sub(lastStake.stakingShares);
            } else {
                // partially redeem a past stake
                stakingShareSecondsToBurn = stakingShareSecondsToBurn
                    .add(sharesLeftToBurn.mul(now.sub(lastStake.timestampSec)));
                lastStake.stakingShares = lastStake.stakingShares.sub(sharesLeftToBurn);
                sharesLeftToBurn = 0;
                break;
            }
        }
        totals.stakingShareSeconds = totals.stakingShareSeconds.sub(stakingShareSecondsToBurn);
        totals.stakingShares = totals.stakingShares.sub(stakingSharesToBurn);
        totals.lastAccountingTimestampSec = now;
        _userTotals[msg.sender] = totals;

        // Calculate the reward amount as a share of user's stakingShareSecondsToBurn to
        // _totalStakingShareSecond.
        uint256 rewardAmount =
            totalUnlocked()
            .mul(stakingShareSecondsToBurn)
            .div(_totalStakingShareSeconds);

        // 2. Global Accounting
        _totalStakingShareSeconds = _totalStakingShareSeconds.sub(stakingShareSecondsToBurn);
        _totalStakingShares = _totalStakingShares.sub(stakingSharesToBurn);
        // Already set in updateAccounting
        // _lastAccountingTimestampSec = now;

        // interactions
        require(_stakingPool.transfer(msg.sender, amount));
        require(_unlockedPool.transfer(msg.sender, rewardAmount));

        emit Unstaked(msg.sender, amount, totalStakedFor(msg.sender), "");
        emit TokensClaimed(msg.sender, rewardAmount);
    }

    /**
     * @param addr The user to look up staking rewards for.
     * @return The number of distribution tokens addr would currently receive for their stake.
     */
    function totalRewardsFor(address addr) public view returns (uint256) {
        return _totalStakingShareSeconds > 0
            ? totalUnlocked()
            .mul(_userTotals[addr].stakingShareSeconds)
            .div(_totalStakingShareSeconds)
            : 0;
    }

    /**
     * @param addr The user to look up staking information for.
     * @return The number of staking tokens deposited for addr.
     */
    function totalStakedFor(address addr) public view returns (uint256) {
        return _totalStakingShares > 0 ?
            totalStaked().mul(_userTotals[addr].stakingShares).div(_totalStakingShares) : 0;
    }

    /**
     * @return The total number of deposit tokens staked globally, by all users.
     */
    function totalStaked() public view returns (uint256) {
        return _stakingPool.balance();
    }

    /**
     * @dev Note that this application has a staking token as well as a distribution token, which
     * may be different. This function is required by EIP-900.
     * @return The deposit token used for staking.
     */
    function token() external view returns (address) {
        return address(getStakingToken());
    }

    /**
     * @return False. This application does not support staking history.
     */
    function supportsHistory() external pure returns (bool) {
        return false;
    }

    /**
     * @dev A globally callable function to update the accounting state of the system.
     *      Global state and state for the caller are updated.
     */
    function updateAccounting() public {
        // unlock tokens
        unlockTokens();

        // Global accounting
        uint256 newStakingShareSeconds =
            now
            .sub(_lastAccountingTimestampSec)
            .mul(_totalStakingShares);
        _totalStakingShareSeconds = _totalStakingShareSeconds.add(newStakingShareSeconds);
        _lastAccountingTimestampSec = now;

        // User Accounting
        UserTotals memory totals = _userTotals[msg.sender];
        uint256 newUserStakingShareSeconds =
            now
            .sub(totals.lastAccountingTimestampSec)
            .mul(totals.stakingShares);
        totals.stakingShareSeconds =
            totals.stakingShareSeconds
            .add(newUserStakingShareSeconds);
        totals.lastAccountingTimestampSec = now;
        _userTotals[msg.sender] = totals;
    }

    /**
     * @return Total number of locked distribution tokens.
     */
    function totalLocked() public view returns (uint256) {
        return _lockedPool.balance();
    }

    /**
     * @return Total number of unlocked distribution tokens.
     */
    function totalUnlocked() public view returns (uint256) {
        return _unlockedPool.balance();
    }

    /**
     * @dev This funcion allows the contract owner to add more locked distribution tokens, along
     *      with the associated "unlock schedule". These locked tokens immediately begin unlocking
     *      linearly over the duraction of durationSec timeframe.
     * @param amount Number of distribution tokens to lock. These are transferred from the caller.
     * @param durationSec Length of time to linear unlock the tokens.
     */
    function lockTokens(uint256 amount, uint256 durationSec) external onlyOwner {
        require(unlockSchedules.length < _maxUnlockSchedules);

        // TODO: If we start with 1 share = 1 token,
        // will we hit rounding errors in the future
        uint256 mintedLockedShares = (totalLocked() > 0)
            ? _totalLockedShares.mul(amount).div(totalLocked())
            : amount;

        UnlockSchedule memory schedule;
        schedule.initialLockedShares = mintedLockedShares;
        schedule.lastUnlockTimestampSec = now;
        schedule.endAtSec = now.add(durationSec);
        schedule.durationSec = durationSec;
        unlockSchedules.push(schedule);

        _totalLockedShares = _totalLockedShares.add(mintedLockedShares);

        require(_lockedPool.getToken().transferFrom(msg.sender, address(_lockedPool), amount));
        emit TokensLocked(amount, durationSec, totalLocked());
    }

    /**
     * @dev Moves distribution tokens from the locked pool to the unlocked pool, according to the
     *      previously defined unlock schedules. Publicly callable.
     * @return Number of newly unlocked distribution tokens.
     */
    function unlockTokens() public returns (uint256) {
        uint256 unlockedTokens = 0;

        if(_totalLockedShares == 0) {
            unlockedTokens = totalLocked();
        } else {
            uint256 unlockedShares = 0;
            for(uint256 s = 0; s < unlockSchedules.length; s++) {
                unlockedShares += unlockScheduleShares(s);
            }
            unlockedTokens = unlockedShares.mul(totalLocked()).div(_totalLockedShares);
            _totalLockedShares = _totalLockedShares.sub(unlockedShares);
        }

        if (unlockedTokens > 0) {
          require(_lockedPool.transfer(address(_unlockedPool), unlockedTokens));
          emit TokensUnlocked(unlockedTokens, totalLocked());
        }

        return unlockedTokens;
    }

    /**
     * @dev Returns the number of unlockable shares from a given schedule. The returned value
     *      depends on the time since the last unlock. This function updates schedule accounting,
     *      but does not actually transfer any tokens.
     * @param s Index of the unlock schedule.
     * @return The number of unlocked shares.
     */
    function unlockScheduleShares(uint256 s) private returns (uint256) {
        UnlockSchedule storage schedule = unlockSchedules[s];

        uint256 unlockTimestampSec = (now < schedule.endAtSec) ? now : schedule.endAtSec;
        uint256 unlockedShares = unlockTimestampSec.sub(schedule.lastUnlockTimestampSec)
            .mul(schedule.initialLockedShares)
            .div(schedule.durationSec);

        schedule.lastUnlockTimestampSec = unlockTimestampSec;

        return unlockedShares;
    }
}
