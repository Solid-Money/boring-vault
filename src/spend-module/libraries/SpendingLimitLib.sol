// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {TimeLib} from "./TimeLib.sol";

/**
 * @notice Rolling daily and monthly spend caps for one Safe, denominated in USD.
 * @dev `pendingDailyLimit` / `pendingMonthlyLimit` only ever hold *increases*; a decrease is
 *      applied straight to `dailyLimit` / `monthlyLimit`. See `SpendingLimitLib` for why.
 */
struct SpendingLimit {
    uint256 dailyLimit;
    uint256 monthlyLimit;
    uint256 spentToday;
    uint256 spentThisMonth;
    uint256 pendingDailyLimit;
    uint256 pendingMonthlyLimit;
    uint64 dailyRenewalTimestamp;
    uint64 monthlyRenewalTimestamp;
    uint64 dailyLimitActivationTime;
    uint64 monthlyLimitActivationTime;
    int256 timezoneOffset;
}

/**
 * @notice Spending-limit accounting for `SolidCashModule`.
 * @dev Adapted from ether.fi's cash-v3 `SpendingLimitLib`, with the limit-change asymmetry
 *      deliberately **inverted**: ether.fi applies increases immediately and delays decreases,
 *      whereas here a *decrease takes effect immediately* and an *increase is delayed*. A limit
 *      increase widens what a compromised backend spender key could take, so it is the
 *      risk-increasing direction and must never be instant; a decrease only ever shrinks the
 *      module's authority and is therefore always safe to apply at once.
 *
 *      Renewal rollover is computed directly from `block.timestamp` rather than by iterating
 *      window-by-window from the stored timestamp, so a Safe dormant for months costs the same
 *      gas as an active one.
 */
library SpendingLimitLib {
    using TimeLib for uint256;

    error ExceededDailySpendingLimit();
    error ExceededMonthlySpendingLimit();
    error DailyLimitCannotBeGreaterThanMonthlyLimit();
    error InvalidTimezoneOffset();
    error NotADecrease();
    error NotAnIncrease();

    /**
     * @notice Seeds a fresh limit and anchors both renewal windows to the user's local clock.
     * @param limit Storage slot to initialize
     * @param dailyLimit Daily cap in USD (6 decimals)
     * @param monthlyLimit Monthly cap in USD (6 decimals)
     * @param timezoneOffset Offset from UTC in seconds, within +/- 24h
     */
    function initialize(SpendingLimit storage limit, uint256 dailyLimit, uint256 monthlyLimit, int256 timezoneOffset)
        internal
    {
        if (dailyLimit > monthlyLimit) revert DailyLimitCannotBeGreaterThanMonthlyLimit();
        if (timezoneOffset > 24 hours || timezoneOffset < -24 hours) revert InvalidTimezoneOffset();

        limit.dailyLimit = dailyLimit;
        limit.monthlyLimit = monthlyLimit;
        limit.timezoneOffset = timezoneOffset;
        limit.dailyRenewalTimestamp = block.timestamp.getStartOfNextDay(timezoneOffset);
        limit.monthlyRenewalTimestamp = block.timestamp.getStartOfNextMonth(timezoneOffset);
    }

    /**
     * @notice Applies every matured time-based transition to a memory copy.
     * @dev The single place window rollover and pending-increase maturation are decided, so the
     *      view path (lens) and the write path (`spend`) can never disagree about the applicable
     *      limit.
     */
    function getCurrentLimit(SpendingLimit memory limit) internal view returns (SpendingLimit memory) {
        if (limit.dailyLimitActivationTime != 0 && block.timestamp > limit.dailyLimitActivationTime) {
            limit.dailyLimit = limit.pendingDailyLimit;
            limit.pendingDailyLimit = 0;
            limit.dailyLimitActivationTime = 0;
        }

        if (limit.monthlyLimitActivationTime != 0 && block.timestamp > limit.monthlyLimitActivationTime) {
            limit.monthlyLimit = limit.pendingMonthlyLimit;
            limit.pendingMonthlyLimit = 0;
            limit.monthlyLimitActivationTime = 0;
        }

        if (block.timestamp > limit.dailyRenewalTimestamp) {
            limit.spentToday = 0;
            limit.dailyRenewalTimestamp = block.timestamp.getStartOfNextDay(limit.timezoneOffset);
        }

        if (block.timestamp > limit.monthlyRenewalTimestamp) {
            limit.spentThisMonth = 0;
            limit.monthlyRenewalTimestamp = block.timestamp.getStartOfNextMonth(limit.timezoneOffset);
        }

        return limit;
    }

    /// @dev Flushes matured transitions from `getCurrentLimit` back into storage.
    function sync(SpendingLimit storage limit) internal {
        SpendingLimit memory current = getCurrentLimit(_load(limit));

        limit.dailyLimit = current.dailyLimit;
        limit.monthlyLimit = current.monthlyLimit;
        limit.spentToday = current.spentToday;
        limit.spentThisMonth = current.spentThisMonth;
        limit.pendingDailyLimit = current.pendingDailyLimit;
        limit.pendingMonthlyLimit = current.pendingMonthlyLimit;
        limit.dailyRenewalTimestamp = current.dailyRenewalTimestamp;
        limit.monthlyRenewalTimestamp = current.monthlyRenewalTimestamp;
        limit.dailyLimitActivationTime = current.dailyLimitActivationTime;
        limit.monthlyLimitActivationTime = current.monthlyLimitActivationTime;
    }

    /**
     * @notice Books `amount` against both windows, reverting if either would be exceeded.
     */
    function spend(SpendingLimit storage limit, uint256 amount) internal {
        sync(limit);

        if (limit.spentToday + amount > limit.dailyLimit) revert ExceededDailySpendingLimit();
        if (limit.spentThisMonth + amount > limit.monthlyLimit) revert ExceededMonthlySpendingLimit();

        limit.spentToday += amount;
        limit.spentThisMonth += amount;
    }

    /**
     * @notice Lowers either cap with immediate effect.
     * @dev Also drops any pending increase: leaving one armed would let the just-revoked
     *      headroom reappear when it matured, silently undoing the user's decision.
     */
    function decrease(SpendingLimit storage limit, uint256 newDailyLimit, uint256 newMonthlyLimit) internal {
        if (newDailyLimit > newMonthlyLimit) revert DailyLimitCannotBeGreaterThanMonthlyLimit();
        sync(limit);
        if (newDailyLimit > limit.dailyLimit || newMonthlyLimit > limit.monthlyLimit) revert NotADecrease();

        limit.dailyLimit = newDailyLimit;
        limit.monthlyLimit = newMonthlyLimit;
        limit.pendingDailyLimit = 0;
        limit.pendingMonthlyLimit = 0;
        limit.dailyLimitActivationTime = 0;
        limit.monthlyLimitActivationTime = 0;
    }

    /**
     * @notice Arms a delayed increase to either cap.
     * @param delay Seconds until the new caps become effective
     */
    function requestIncrease(
        SpendingLimit storage limit,
        uint256 newDailyLimit,
        uint256 newMonthlyLimit,
        uint64 delay
    ) internal {
        if (newDailyLimit > newMonthlyLimit) revert DailyLimitCannotBeGreaterThanMonthlyLimit();
        sync(limit);
        if (newDailyLimit < limit.dailyLimit || newMonthlyLimit < limit.monthlyLimit) revert NotAnIncrease();

        uint64 activationTime = uint64(block.timestamp) + delay;
        limit.pendingDailyLimit = newDailyLimit;
        limit.pendingMonthlyLimit = newMonthlyLimit;
        limit.dailyLimitActivationTime = activationTime;
        limit.monthlyLimitActivationTime = activationTime;
    }

    /// @notice Disarms a pending increase before it matures.
    function cancelPendingIncrease(SpendingLimit storage limit) internal {
        sync(limit);
        limit.pendingDailyLimit = 0;
        limit.pendingMonthlyLimit = 0;
        limit.dailyLimitActivationTime = 0;
        limit.monthlyLimitActivationTime = 0;
    }

    /**
     * @notice Headroom left under the tighter of the two windows.
     * @dev A pending increase is ignored until matured, so this is always the conservative
     *      figure the authorize path should quote against.
     */
    function maxCanSpend(SpendingLimit memory limit) internal view returns (uint256) {
        limit = getCurrentLimit(limit);

        if (limit.spentToday >= limit.dailyLimit) return 0;
        if (limit.spentThisMonth >= limit.monthlyLimit) return 0;

        uint256 availableDaily = limit.dailyLimit - limit.spentToday;
        uint256 availableMonthly = limit.monthlyLimit - limit.spentThisMonth;

        return availableDaily < availableMonthly ? availableDaily : availableMonthly;
    }

    /// @dev Storage-to-memory copy; `SpendingLimit memory x = storagePtr` is not implicit here.
    function _load(SpendingLimit storage limit) private view returns (SpendingLimit memory) {
        return SpendingLimit({
            dailyLimit: limit.dailyLimit,
            monthlyLimit: limit.monthlyLimit,
            spentToday: limit.spentToday,
            spentThisMonth: limit.spentThisMonth,
            pendingDailyLimit: limit.pendingDailyLimit,
            pendingMonthlyLimit: limit.pendingMonthlyLimit,
            dailyRenewalTimestamp: limit.dailyRenewalTimestamp,
            monthlyRenewalTimestamp: limit.monthlyRenewalTimestamp,
            dailyLimitActivationTime: limit.dailyLimitActivationTime,
            monthlyLimitActivationTime: limit.monthlyLimitActivationTime,
            timezoneOffset: limit.timezoneOffset
        });
    }

    /// @notice Public storage-to-memory reader for the module and lens view paths.
    function load(SpendingLimit storage limit) internal view returns (SpendingLimit memory) {
        return _load(limit);
    }
}
