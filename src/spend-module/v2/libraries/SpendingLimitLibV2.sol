// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {TimeLib} from "../../libraries/TimeLib.sol";
import {SpendingLimit} from "../../libraries/SpendingLimitLib.sol";

/**
 * @notice EXTERNAL variant of `SpendingLimitLib`, deployed once and delegatecalled.
 * @dev Identical logic, `public` instead of `internal`, so its bytecode lives in its own account
 *      rather than inside `SolidCashModuleV2` — which is what keeps the module inside EIP-170. This
 *      is the same technique ether.fi uses for `CashLendLib`. Deployment therefore requires linking.
 *
 * Rolling daily and monthly spend caps for one Safe, denominated in USD.
 * @dev `pendingDailyLimit` / `pendingMonthlyLimit` only ever hold *increases*; a decrease is
 *      applied straight to `dailyLimit` / `monthlyLimit`. See `SpendingLimitLib` for why.
 */

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
library SpendingLimitLibV2 {
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
        public
    {
        if (dailyLimit > monthlyLimit) revert DailyLimitCannotBeGreaterThanMonthlyLimit();
        if (timezoneOffset > 24 hours || timezoneOffset < -24 hours) revert InvalidTimezoneOffset();

        limit.dailyLimit = dailyLimit;
        limit.monthlyLimit = monthlyLimit;
        limit.timezoneOffset = timezoneOffset;
        limit.dailyRenewalTimestamp = block.timestamp.getStartOfNextDay(timezoneOffset);
        limit.monthlyRenewalTimestamp = block.timestamp.getStartOfNextMonth(timezoneOffset);

        // Written explicitly rather than assumed. This used to depend on the caller having handed
        // over virgin storage, which made "is this slot clean?" a property of a distant call site
        // instead of a property of the function that seeds it.
        limit.spentToday = 0;
        limit.spentThisMonth = 0;
        limit.pendingDailyLimit = 0;
        limit.pendingMonthlyLimit = 0;
        limit.dailyLimitActivationTime = 0;
        limit.monthlyLimitActivationTime = 0;
    }

    /**
     * @notice Re-seeds a limit that has already been used, without forgiving what it has spent.
     * @dev The re-registration path. Deregistering and registering again must not be a way to
     *      obtain a fresh daily window, and must not be a way to reach a higher cap without waiting
     *      out `limitRaiseDelay` — so this keeps `spentToday`, `spentThisMonth` and both renewal
     *      windows, and refuses anything that is not a decrease. A returning Safe that wants more
     *      headroom asks for it through `requestIncrease`, like everyone else.
     */
    function reinitialize(SpendingLimit storage limit, uint256 dailyLimit, uint256 monthlyLimit, int256 timezoneOffset)
        public
    {
        if (dailyLimit > monthlyLimit) revert DailyLimitCannotBeGreaterThanMonthlyLimit();
        if (timezoneOffset > 24 hours || timezoneOffset < -24 hours) revert InvalidTimezoneOffset();

        sync(limit);

        // Clamped rather than rejected, so a returning Safe asking for the org default does not
        // simply revert — it just does not get more than it left with.
        if (dailyLimit > limit.dailyLimit) dailyLimit = limit.dailyLimit;
        if (monthlyLimit > limit.monthlyLimit) monthlyLimit = limit.monthlyLimit;
        if (dailyLimit > monthlyLimit) dailyLimit = monthlyLimit;

        limit.dailyLimit = dailyLimit;
        limit.monthlyLimit = monthlyLimit;
        limit.timezoneOffset = timezoneOffset;
        limit.pendingDailyLimit = 0;
        limit.pendingMonthlyLimit = 0;
        limit.dailyLimitActivationTime = 0;
        limit.monthlyLimitActivationTime = 0;
    }

    /**
     * @notice Seeds a limit at registration time, fresh or returning.
     * @dev One entry point so the caller does not have to know which case it is in — and so the
     *      "has this Safe been here before?" test lives next to the two functions that answer it.
     *      `dailyRenewalTimestamp` is set by `initialize` and never returns to zero, so it is the
     *      marker; `deregisterSafe` cannot clear it, because the limit is not part of the struct it
     *      deletes.
     */
    function seedForRegistration(
        SpendingLimit storage limit,
        uint256 dailyLimit,
        uint256 monthlyLimit,
        int256 timezoneOffset
    ) public {
        if (limit.dailyRenewalTimestamp == 0) initialize(limit, dailyLimit, monthlyLimit, timezoneOffset);
        else reinitialize(limit, dailyLimit, monthlyLimit, timezoneOffset);
    }

    /**
     * @notice Applies every matured time-based transition to a memory copy.
     * @dev The single place window rollover and pending-increase maturation are decided, so the
     *      view path (lens) and the write path (`spend`) can never disagree about the applicable
     *      limit.
     */
    function getCurrentLimit(SpendingLimit memory limit) public view returns (SpendingLimit memory) {
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
    function sync(SpendingLimit storage limit) public {
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
    function spend(SpendingLimit storage limit, uint256 amount) public {
        sync(limit);

        if (limit.spentToday + amount > limit.dailyLimit) revert ExceededDailySpendingLimit();
        if (limit.spentThisMonth + amount > limit.monthlyLimit) revert ExceededMonthlySpendingLimit();

        limit.spentToday += amount;
        limit.spentThisMonth += amount;
    }

    /**
     * @notice Books `amount` against both windows **without enforcing either cap**.
     * @dev Only reachable while a spending-limit waiver is in force. Accumulating anyway is what
     *      stops a waiver from handing the user a fresh window the moment it is lifted, and keeps
     *      the reported volume true throughout.
     */
    function recordSpend(SpendingLimit storage limit, uint256 amount) public {
        sync(limit);
        limit.spentToday += amount;
        limit.spentThisMonth += amount;
    }

    /**
     * @notice Lowers either cap with immediate effect.
     * @dev Also drops any pending increase: leaving one armed would let the just-revoked
     *      headroom reappear when it matured, silently undoing the user's decision.
     */
    function decrease(SpendingLimit storage limit, uint256 newDailyLimit, uint256 newMonthlyLimit) public {
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
    function requestIncrease(SpendingLimit storage limit, uint256 newDailyLimit, uint256 newMonthlyLimit, uint64 delay)
        public
    {
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
    function cancelPendingIncrease(SpendingLimit storage limit) public {
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
    function maxCanSpend(SpendingLimit memory limit) public view returns (uint256) {
        limit = getCurrentLimit(limit);

        if (limit.spentToday >= limit.dailyLimit) return 0;
        if (limit.spentThisMonth >= limit.monthlyLimit) return 0;

        uint256 availableDaily = limit.dailyLimit - limit.spentToday;
        uint256 availableMonthly = limit.monthlyLimit - limit.spentThisMonth;

        return availableDaily < availableMonthly ? availableDaily : availableMonthly;
    }

    /**
     * @notice The limit with every matured transition applied, read straight from storage.
     * @dev One call rather than `load` then `getCurrentLimit`. Each of those crosses the
     *      `delegatecall` boundary with an eleven-field struct in both directions, and the ABI
     *      coder for that round trip is emitted into the CALLER — which is the contract with the
     *      EIP-170 problem, not this one.
     */
    function currentLimit(SpendingLimit storage limit) public view returns (SpendingLimit memory) {
        return getCurrentLimit(_load(limit));
    }

    /**
     * @notice Headroom under a Safe's own windows, clamped by the live org ceilings, in one call.
     * @dev Clamping on read rather than only at registration is what makes lowering a ceiling a
     *      real, immediate control over Safes that registered under a looser one. Folded in here
     *      for the same reason as `currentLimit`: three struct round trips became one uint.
     */
    function maxCanSpendClamped(SpendingLimit storage limit, uint256 dailyCeiling, uint256 monthlyCeiling)
        public
        view
        returns (uint256)
    {
        SpendingLimit memory current = getCurrentLimit(_load(limit));

        if (current.dailyLimit > dailyCeiling) current.dailyLimit = dailyCeiling;
        if (current.monthlyLimit > monthlyCeiling) current.monthlyLimit = monthlyCeiling;

        if (current.spentToday >= current.dailyLimit) return 0;
        if (current.spentThisMonth >= current.monthlyLimit) return 0;

        uint256 availableDaily = current.dailyLimit - current.spentToday;
        uint256 availableMonthly = current.monthlyLimit - current.spentThisMonth;

        return availableDaily < availableMonthly ? availableDaily : availableMonthly;
    }

    /// @dev Storage-to-memory copy; `SpendingLimit memory x = storagePtr` is not implicit here.
    function _load(SpendingLimit storage limit) internal view returns (SpendingLimit memory) {
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
    function load(SpendingLimit storage limit) public view returns (SpendingLimit memory) {
        return _load(limit);
    }
}
