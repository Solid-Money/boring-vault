// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SpendingLimit} from "../libraries/SpendingLimitLib.sol";
import {Mode, Params, TokenConfig} from "./SolidCashTypes.sol";

/// @dev The slice of the deployed v1 `SolidCashModule` this lens reads.
interface ISolidCashModuleV1 {
    function isRegistered(address safe) external view returns (bool);
    function isModuleEnabledOn(address safe) external view returns (bool);
    function isPaused() external view returns (bool);
    function safePaused(address safe) external view returns (bool);
    function maxPerTxUsd() external view returns (uint256);
    function spendableUsd(address safe) external view returns (uint256);
    function maxCanSpendUsd(address safe) external view returns (uint256);
    function applicableSpendingLimit(address safe) external view returns (SpendingLimit memory);
    function perTokenSpendable(address safe)
        external
        view
        returns (address[] memory, uint256[] memory, uint256[] memory, uint256[] memory);
}

/// @dev The slice of `SolidCashModuleV2` this lens reads. `getTokenConfig` and `getParams` live in
///      the setters half and are reached through the core's fallback, which is read-only for them.
interface ISolidCashModuleV2Read {
    function isRegistered(address safe) external view returns (bool);
    function isModuleEnabledOn(address safe) external view returns (bool);
    function isLegacyEnabledOn(address safe) external view returns (bool);
    function isPaused() external view returns (bool);
    function safePaused(address safe) external view returns (bool);
    function getMode(address safe) external view returns (Mode);
    function getIncomingMode(address safe) external view returns (Mode);
    function incomingModeStartTime(address safe) external view returns (uint64);
    function unhealthySince(address safe) external view returns (uint64);
    function allowedTokens() external view returns (address[] memory);
    function collateralOf(address safe, address token) external view returns (uint256);
    function tokenPaused(address token) external view returns (bool);
    function getPriceUsd(address token) external view returns (uint256, bool, bool);
    function positionValue(address safe) external view returns (uint256, uint256, bool);
    function debtUsd(address safe) external view returns (uint256);
    function totalDebtUsd() external view returns (uint256);
    function healthFactor(address safe) external view returns (uint256);
    function maxCanSpendUsd(address safe) external view returns (uint256);
    function limitsWaived(address safe) external view returns (bool);
    function applicableSpendingLimit(address safe) external view returns (SpendingLimit memory);
    function effectiveTargetLtv(address token) external view returns (uint256);
    function getTokenConfig(address token) external view returns (TokenConfig memory);
    function getParams() external view returns (Params memory);
    function booked(address safe, bytes32 txId) external view returns (uint72, uint72, uint72, bool, bool, bool);
}

/// @notice One allowlisted asset's contribution, for a decline reason and for token selection.
struct TokenAvailability {
    address token;
    uint256 amount;
    uint256 priceUsd;
    bool priceUsable;
    uint256 valueUsd;
}

/// @notice What the authorize path needs to decide a Debit-mode spend.
struct DebitAvailability {
    uint256 spendableUsd;
    uint256 limitRemainingUsd;
    uint256 maxPerTxUsd;
    bool anyPriceUnusable;
    TokenAvailability[] perToken;
}

/// @notice What the authorize path needs to decide a Credit-mode spend.
struct CreditAvailability {
    uint256 collateralUsd;
    uint256 borrowingPowerUsd;
    uint256 liquidationCapacityUsd;
    uint256 debtUsd;
    uint256 healthFactorWad;
    uint256 availableToBorrowUsd;
    uint256 prospectiveCollateralUsd;
    bool fullyPriced;
    bool liquidatable;
    uint64 unhealthySince;
    TokenAvailability[] perCollateral;
}

/// @notice Everything about one Safe, as of one block.
struct UnifiedAvailability {
    uint8 cohort;
    bool moduleEnabled;
    bool registered;
    bool modulePaused;
    bool safePausedFlag;
    /// @dev True when the per-transaction and rolling caps are waived for this Safe. Collateral and
    ///      the global debt cap still bind, so this is not "unlimited".
    bool limitsWaived;
    Mode activeMode;
    /**
     * @dev The mode an armed switch will move to, or `activeMode` when nothing is armed.
     *
     *      `incomingModeStartTime` alone says WHEN a switch matures but not what it matures into,
     *      which with three modes is no longer inferable — a client could only show a countdown to
     *      an unnamed mode.
     */
    Mode incomingMode;
    uint64 incomingModeStartTime;
    DebitAvailability debit;
    CreditAvailability credit;
    SpendingLimit limit;
    uint256 blockNumber;
    uint256 blockTimestamp;
}

/**
 * @title SolidSpendLens
 * @notice Read-only aggregator answering "may this card transaction proceed, for how much, and out
 *         of which assets?" in a single `eth_call`, for either module cohort.
 *
 * @dev **Exists for latency first.** Wirex's External Authorization contract gives a 300ms target
 *      and a 500ms hard timeout for the whole decision, and a timeout is treated as a decline.
 *      Reading N balances plus N prices plus limits plus debt over separate calls cannot fit that
 *      budget, so the aggregation is pushed on-chain and the hot path makes exactly one round trip
 *      to a co-located Fuse node. One call also guarantees every field is evaluated at the **same
 *      block**, which the caller's in-flight subtraction depends on.
 *
 *      **Cohort-aware, because v1 stays live.** Migration to v2 is per-user and has no deadline, so
 *      at any moment some Safes are on v1 and some on v2. `cohort` tells the backend which module to
 *      route execution to, and `COHORT_BOTH` — a migrated Safe that has manually re-enabled v1, and
 *      whose v2 is therefore inert — routes to v1, which still works.
 *
 *      **Where the logic lives.** Every decision input is read from the module, never recomputed:
 *      prices come from `getPriceUsd` (so they carry the module's own band and staleness bound),
 *      position value from `positionValue`, limits from `maxCanSpendUsd`. What this contract adds is
 *      composition and presentation. That split is deliberate: the module is authoritative and will
 *      revert on anything it disagrees with, so a drift here can only ever cost an unnecessary
 *      decline, never an approval the module would refuse.
 *
 *      `prospectiveCollateralUsd` is the one figure with no module equivalent, and it is quoted at
 *      `effectiveTargetLtv` — the same buffered ratio `spendCredit` locks at — so a quote can never
 *      advertise more power than execution would back.
 */
contract SolidSpendLens {
    using Math for uint256;

    uint8 public constant COHORT_NONE = 0;
    uint8 public constant COHORT_V1 = 1;
    uint8 public constant COHORT_V2 = 2;
    /// @notice Both modules enabled: v2 refuses to act, so execution must route to v1.
    uint8 public constant COHORT_BOTH = 3;

    uint256 private constant WAD = 1e18;

    ISolidCashModuleV1 public immutable v1;
    ISolidCashModuleV2Read public immutable v2;

    error InvalidInput();

    constructor(address _v1, address _v2) {
        if (_v1 == address(0) || _v2 == address(0)) revert InvalidInput();
        v1 = ISolidCashModuleV1(_v1);
        v2 = ISolidCashModuleV2Read(_v2);
    }

    /**
     * @notice The authorize path's single read.
     * @dev Every gate is reported rather than collapsed into one boolean, so a decline can be given
     *      an accurate reason and ops can tell a paused module from an empty Safe or a dead feed.
     *      The spendable and borrowable figures are already 0 whenever a gate fails.
     */
    function availableToSpend(address safe) public view returns (UnifiedAvailability memory) {
        address[] memory whole;
        return _availableToSpend(safe, whole, false);
    }

    /**
     * @notice `availableToSpend` restricted to an explicit token set.
     * @dev The authorize path's escape hatch from the allowlist's length. Both v2 loops walk every
     *      allowlisted token with a price read each, and the module caps the allowlist for exactly
     *      that reason — but a caller that already knows which assets a Safe can use should not pay
     *      for the rest against a 500ms budget where a timeout is a decline.
     *
     *      Only ever narrower than the module's own view, so the same guarantee holds: the module
     *      is authoritative and will refuse anything it disagrees with, so a subset can cost an
     *      unnecessary decline and never an approval `spend` would reject. Ignored for v1 Safes,
     *      whose figures come from v1 pre-aggregated.
     */
    function availableToSpendWith(address safe, address[] calldata tokens)
        external
        view
        returns (UnifiedAvailability memory)
    {
        return _availableToSpend(safe, tokens, true);
    }

    function _availableToSpend(address safe, address[] memory tokens, bool restricted)
        private
        view
        returns (UnifiedAvailability memory data)
    {
        data.cohort = cohortOf(safe);
        data.blockNumber = block.number;
        data.blockTimestamp = block.timestamp;

        if (data.cohort == COHORT_V2) {
            if (!restricted) tokens = v2.allowedTokens();
            Params memory p = v2.getParams();

            data.moduleEnabled = true;
            data.registered = true;
            data.modulePaused = v2.isPaused();
            data.safePausedFlag = v2.safePaused(safe);
            data.activeMode = v2.getMode(safe);
            data.incomingMode = v2.getIncomingMode(safe);
            data.incomingModeStartTime = v2.incomingModeStartTime(safe);
            data.limit = v2.applicableSpendingLimit(safe);
            data.limitsWaived = v2.limitsWaived(safe);
            data.debit = _debitV2(safe, tokens, p, data.modulePaused || data.safePausedFlag, data.limitsWaived);
            data.credit = _creditV2(safe, tokens, p, data.modulePaused || data.safePausedFlag, data.limitsWaived);
        } else if (data.cohort == COHORT_V1 || data.cohort == COHORT_BOTH) {
            data.moduleEnabled = true;
            // `COHORT_BOTH` is decided from v2 state alone, so a Safe that migrated and then
            // re-enabled v1 without ever registering there routes to v1 and is not registered on it.
            // Reporting `true` regardless turned a clean "not registered" into a mystery decline.
            data.registered = data.cohort == COHORT_V1 || v1.isRegistered(safe);
            data.modulePaused = v1.isPaused();
            data.safePausedFlag = v1.safePaused(safe);
            data.activeMode = Mode.Debit;
            data.incomingMode = Mode.Debit;
            data.limit = v1.applicableSpendingLimit(safe);
            data.debit = _debitV1(safe);
        }
    }

    /**
     * @notice Which module operates `safe`.
     * @dev v2 is checked first because a migrated Safe is the steady state. `COHORT_BOTH` is the
     *      anomaly a user creates by re-enabling v1 after migrating: v2's own write paths refuse in
     *      that state, so reporting it distinctly is what lets the backend route to the module that
     *      still works instead of eating a revert.
     */
    function cohortOf(address safe) public view returns (uint8) {
        bool onV2 = v2.isRegistered(safe) && v2.isModuleEnabledOn(safe);
        bool legacyEnabled = v2.isLegacyEnabledOn(safe);

        if (onV2) return legacyEnabled ? COHORT_BOTH : COHORT_V2;
        if (v1.isRegistered(safe) && v1.isModuleEnabledOn(safe)) return COHORT_V1;
        return COHORT_NONE;
    }

    // ========================================= V2 =========================================

    function _debitV2(address safe, address[] memory tokens, Params memory p, bool paused, bool waived)
        private
        view
        returns (DebitAvailability memory d)
    {
        // A waived Safe is bounded only by what it holds, so quoting the capped figure would decline
        // spends `spend` would happily execute. `type(uint256).max` makes the caller's own `min`
        // collapse to the balance-derived bound.
        d.maxPerTxUsd = waived ? type(uint256).max : p.maxPerTxUsd;
        d.limitRemainingUsd = waived ? type(uint256).max : v2.maxCanSpendUsd(safe);

        d.perToken = new TokenAvailability[](tokens.length);

        uint256 totalUsd;
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenConfig memory cfg = v2.getTokenConfig(tokens[i]);
            (uint256 price, bool usable,) = v2.getPriceUsd(tokens[i]);
            uint256 balance = IERC20(tokens[i]).balanceOf(safe);

            uint256 valueUsd;
            if (usable && cfg.spendable && !v2.tokenPaused(tokens[i]) && balance != 0) {
                // The haircut is quote-only and never touches settlement, so a quote can only ever
                // be more conservative than what `spend` would actually charge.
                valueUsd = balance.mulDiv(price, 10 ** cfg.tokenDecimals, Math.Rounding.Floor).mulDiv(
                    10_000 - cfg.haircutBps, 10_000, Math.Rounding.Floor
                );
                totalUsd += valueUsd;
            } else if (!usable && balance != 0) {
                // A held asset we cannot price is the case worth surfacing: it silently understates
                // the user's power, so it looks like "insufficient funds" to them and like nothing
                // at all to us.
                d.anyPriceUnusable = true;
            }

            d.perToken[i] = TokenAvailability(tokens[i], balance, usable ? price : 0, usable, valueUsd);
        }

        if (paused) return d;

        if (totalUsd > p.dustFloorUsd) totalUsd -= p.dustFloorUsd;
        else totalUsd = 0;

        d.spendableUsd = totalUsd < d.limitRemainingUsd ? totalUsd : d.limitRemainingUsd;
    }

    function _creditV2(address safe, address[] memory tokens, Params memory p, bool paused, bool waived)
        private
        view
        returns (CreditAvailability memory c)
    {
        (c.borrowingPowerUsd, c.liquidationCapacityUsd, c.fullyPriced) = v2.positionValue(safe);
        c.debtUsd = v2.debtUsd(safe);
        c.healthFactorWad = v2.healthFactor(safe);
        c.liquidatable = c.healthFactorWad < WAD;
        c.unhealthySince = v2.unhealthySince(safe);

        c.perCollateral = new TokenAvailability[](tokens.length);

        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenConfig memory cfg = v2.getTokenConfig(tokens[i]);
            (uint256 price, bool usable,) = v2.getPriceUsd(tokens[i]);
            uint256 escrowed = v2.collateralOf(safe, tokens[i]);

            uint256 valueUsd;
            if (usable && escrowed != 0) {
                valueUsd = escrowed.mulDiv(price, 10 ** cfg.tokenDecimals, Math.Rounding.Floor);
                c.collateralUsd += valueUsd;
            }

            c.perCollateral[i] = TokenAvailability(tokens[i], escrowed, usable ? price : 0, usable, valueUsd);

            // Quoted at the SAME buffered ratio `_lockOne` sizes at, so this can never advertise
            // more power than execution would actually back.
            if (usable && cfg.collateral && !v2.tokenPaused(tokens[i])) {
                uint256 loose = IERC20(tokens[i]).balanceOf(safe);
                if (loose != 0) {
                    uint256 looseUsd = loose.mulDiv(price, 10 ** cfg.tokenDecimals, Math.Rounding.Floor);
                    c.prospectiveCollateralUsd +=
                        looseUsd.mulDiv(v2.effectiveTargetLtv(tokens[i]), WAD, Math.Rounding.Floor);
                }
            }
        }

        if (paused) return c;
        c.availableToBorrowUsd = _borrowable(safe, c, p, waived);
    }

    /**
     * @dev Borrow headroom, clamped by every cap that still binds. Any exhausted cap yields zero.
     *
     *      A waiver lifts the per-Safe debt cap and the rolling windows, mirroring the module's own
     *      `limitsWaived` boundary exactly. It never lifts the collateral requirement — `power` is
     *      the first clamp regardless — and it never lifts `maxGlobalDebtUsd`, which is Solid's float
     *      solvency rather than one user's allowance.
     */
    function _borrowable(address safe, CreditAvailability memory c, Params memory p, bool waived)
        private
        view
        returns (uint256)
    {
        uint256 power = c.borrowingPowerUsd + c.prospectiveCollateralUsd;
        if (power <= c.debtUsd) return 0;
        uint256 headroom = power - c.debtUsd;

        uint256 room;
        if (!waived) {
            if (c.debtUsd >= p.maxDebtPerSafeUsd) return 0;
            room = p.maxDebtPerSafeUsd - c.debtUsd;
            if (headroom > room) headroom = room;
        }

        uint256 total = v2.totalDebtUsd();
        if (total >= p.maxGlobalDebtUsd) return 0;
        room = p.maxGlobalDebtUsd - total;
        if (headroom > room) headroom = room;

        if (waived) return headroom;

        room = v2.maxCanSpendUsd(safe);
        return headroom < room ? headroom : room;
    }

    // ========================================= V1 =========================================

    function _debitV1(address safe) private view returns (DebitAvailability memory d) {
        d.spendableUsd = v1.spendableUsd(safe);
        d.limitRemainingUsd = v1.maxCanSpendUsd(safe);
        d.maxPerTxUsd = v1.maxPerTxUsd();

        (address[] memory tokens, uint256[] memory balances, uint256[] memory prices, uint256[] memory values) =
            v1.perTokenSpendable(safe);

        d.perToken = new TokenAvailability[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            bool usable = prices[i] != 0;
            if (!usable && balances[i] != 0) d.anyPriceUnusable = true;
            d.perToken[i] = TokenAvailability(tokens[i], balances[i], prices[i], usable, values[i]);
        }
    }

    // ========================================= BATCH =========================================

    /**
     * @notice `availableToSpend` for many Safes, for reconciliation and ops sweeps.
     * @dev Not for the authorize path, which only ever cares about one Safe and must keep its
     *      calldata and gas bounded.
     */
    function availableToSpendBatch(address[] calldata safes)
        external
        view
        returns (UnifiedAvailability[] memory data)
    {
        data = new UnifiedAvailability[](safes.length);
        for (uint256 i = 0; i < safes.length; ++i) {
            data[i] = availableToSpend(safes[i]);
        }
    }
}
