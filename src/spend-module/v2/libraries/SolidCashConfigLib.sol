// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ISafe} from "../../interfaces/ISafe.sol";
import {ISolidPriceProviderV2} from "../interfaces/ISolidPriceProviderV2.sol";
import {Params, TokenConfig} from "../SolidCashTypes.sol";

/**
 * @title SolidCashConfigLib
 * @notice The configuration bounds and risk classifications the setters apply, plus the two bounded
 *         external reads both halves of the module need.
 * @dev `public` rather than `internal`, so it deploys to its own account and is delegatecalled —
 *      which is what keeps ~1KB of validation out of the setters' EIP-170 budget. Deployment
 *      therefore requires linking, alongside `SpendingLimitLibV2` and `SolidCreditMathLib`.
 *
 *      Being pure is the point beyond size. Whether a given configuration change is risk-increasing
 *      is the question the whole delayed-change mechanism turns on, and here it can be fuzzed
 *      directly against a pair of structs with no deployment, no roles and no clock.
 */
library SolidCashConfigLib {
    uint256 internal constant WAD = 1e18;
    uint16 internal constant MAX_BPS = 10_000;

    /// @notice Ceiling on a per-token haircut; at or above this, quoted power would be erased.
    uint16 public constant MAX_HAIRCUT_BPS = 5_000;

    /// @notice Ceiling on every governance delay, so a delay cannot be made unreachable.
    uint64 public constant MAX_DELAY = 30 days;

    /**
     * @notice Floor under the liquidation grace period.
     * @dev `setParams` has no delay of its own, so without floors it could zero every delay in one
     *      transaction and apply any risk-increasing change in the next — which would make the
     *      whole delayed-change mechanism a two-transaction bypass rather than a protection. Grace
     *      is the one that protects users from a single wrong rate print, so it gets a floor.
     */
    uint64 public constant MIN_LIQUIDATION_GRACE = 10 minutes;

    /// @notice Floor under `collateralWithdrawDelay`. Its job is only to stop a withdrawal racing an
    ///         in-flight `spendCredit` — seconds, not days — but zero would remove even that.
    uint64 public constant MIN_COLLATERAL_WITHDRAW_DELAY = 1 minutes;

    /// @notice Ceiling on `targetLtvBps`. Sizing collateral at a token's full LTV opens every
    ///         position exactly at its bound, where one unit of rounding decides whether a credit
    ///         spend succeeds — and puts the deleverage cron in play from the very first spend.
    uint16 public constant MAX_TARGET_LTV_BPS = 9_500;

    /**
     * @notice Ceiling on `graceFloorHf`, so the grace period cannot be switched off by a parameter.
     * @dev `graceFloorHf` is the health factor below which liquidation skips the grace period,
     *      because a position that deep is in a real crash rather than under a single bad print. At
     *      `1e18` every unhealthy position is below it by definition, so the whole grace period
     *      would be unreachable — and `setParams` has no delay of its own, which is the same
     *      two-transaction bypass `MIN_LIQUIDATION_GRACE` exists to close. Capping this leaves a
     *      shallow band in which grace always applies.
     */
    uint64 public constant MAX_GRACE_FLOOR_HF = 0.98e18;

    /**
     * @notice Gas forwarded to the price provider.
     * @dev The provider is upgradeable and documents itself as never reverting, but two of its four
     *      feed families reach a contract this module does not control. Bounding the read is what
     *      stops one of them consuming the authorize path's whole budget.
     */
    uint256 internal constant PROVIDER_GAS_LIMIT = 600_000;

    error InvalidInput();
    error InvalidRiskParams();

    /**
     * @notice Every bound on one token's risk parameters.
     * @dev A threshold at or below the LTV would let a position be liquidatable the instant it is
     *      opened; a threshold plus bonus above 100% would let a liquidation seize more value than
     *      the position holds.
     */
    function validateTokenConfig(TokenConfig memory cfg) public pure {
        if (cfg.haircutBps > MAX_HAIRCUT_BPS) revert InvalidRiskParams();
        if (cfg.minPriceUsd == 0 || cfg.maxPriceUsd < cfg.minPriceUsd) revert InvalidRiskParams();
        if (cfg.ltv > WAD || cfg.liquidationThreshold > WAD) revert InvalidRiskParams();

        if (cfg.collateral) {
            if (cfg.ltv == 0 || cfg.liquidationThreshold <= cfg.ltv) revert InvalidRiskParams();
            if (uint256(cfg.liquidationThreshold) + (uint256(cfg.liquidationBonusBps) * WAD) / MAX_BPS > WAD) {
                revert InvalidRiskParams();
            }
        }

        if (cfg.ceilingGrowthPerSec != 0) {
            // A drift with no anchor would be measured from the epoch, which is not a ceiling.
            if (cfg.ceilingAnchor == 0) revert InvalidRiskParams();
            // At most 100% of the anchored ceiling per year, so this stays a bound on the RATE of
            // change rather than an open-ended licence for the ceiling to run away unattended.
            if (uint256(cfg.ceilingGrowthPerSec) * 365 days > uint256(cfg.maxPriceUsd) * WAD) {
                revert InvalidRiskParams();
            }
        }

        if (cfg.maxStalenessSeconds > MAX_DELAY) revert InvalidRiskParams();
    }

    /**
     * @notice Whether moving from `from` to `to` increases risk, and therefore must wait out
     *         `paramChangeDelay`.
     * @dev Two distinct kinds of risk are covered, and both belong here.
     *
     *      **Risk to an existing borrower**: a lower LTV, a LOWER liquidation threshold, a bigger
     *      bonus, a tighter band, a stricter staleness bound. Applying these at once is how
     *      `DebtManagerAdmin._setCollateralTokenConfig` lets governance make currently-healthy
     *      positions instantly liquidatable — and therefore liquidate its own users' collateral in
     *      a single transaction.
     *
     *      **Risk to a holder from a widened module**: making a token newly sellable or newly
     *      pledgeable. `collateral: true, spendable: false` is presented to users as a structural
     *      guarantee that their soETH is not sold to buy coffee. That is not structural if the flag
     *      can be flipped in one immediate transaction, after which the next swipe sells it.
     *      Turning either flag OFF stays immediate, because that only ever narrows what the module
     *      may do.
     */
    function isRiskIncreasing(TokenConfig memory from, TokenConfig memory to) public pure returns (bool) {
        if (!from.spendable && to.spendable) return true;
        if (!from.collateral && to.collateral) return true;
        if (from.collateral && !to.collateral) return true;

        if (to.ltv < from.ltv) return true;
        // **Lowering** the threshold is the dangerous direction, and this comparison used to point
        // the other way. Liquidation capacity is `value * liquidationThreshold`, so a lower
        // threshold shrinks capacity, drops every existing borrower's health factor, and can make a
        // currently-healthy position seizable in the same transaction — which is exactly the
        // `DebtManagerAdmin._setCollateralTokenConfig` failure this whole mechanism exists to avoid.
        // Raising it only ever adds headroom, so it applies immediately.
        if (to.liquidationThreshold < from.liquidationThreshold) return true;
        if (to.liquidationBonusBps > from.liquidationBonusBps) return true;
        if (to.haircutBps > from.haircutBps) return true;

        // Tightening the band can make a token unpriceable, which removes it from liquidation
        // capacity and drops the health factor. `setTokenPaused` is the immediate lever instead,
        // because it is capacity-preserving.
        if (to.minPriceUsd > from.minPriceUsd) return true;
        if (to.maxPriceUsd < from.maxPriceUsd) return true;
        // Slowing the drift, or re-anchoring it later, both lower the ceiling from here on.
        if (to.ceilingGrowthPerSec < from.ceilingGrowthPerSec) return true;
        if (to.ceilingAnchor > from.ceilingAnchor) return true;

        if (
            to.maxStalenessSeconds != 0
                && (from.maxStalenessSeconds == 0 || to.maxStalenessSeconds < from.maxStalenessSeconds)
        ) return true;

        return false;
    }

    /**
     * @notice Every bound and cross-field relationship on the org-wide parameter set.
     * @dev `currentParamChangeDelay` is passed in because the one parameter this function may not
     *      lower is the one every other delayed change is measured against. Raising it is immediate;
     *      shortening it has to wait out the window it is about to remove, which is what
     *      `requestParamChangeDelayReduction` is for. Without that asymmetry, `setParams` — which
     *      has no delay of its own — could zero every delay in one transaction and apply anything
     *      in the next, making the whole mechanism a two-transaction bypass.
     */
    function validateParams(Params memory p, uint64 currentParamChangeDelay) public pure {
        if (p.maxPerTxUsd > p.maxDailyLimitUsd) revert InvalidInput();
        if (p.maxDailyLimitUsd > p.maxMonthlyLimitUsd) revert InvalidInput();
        if (p.defaultDailyLimitUsd > p.maxDailyLimitUsd) revert InvalidInput();
        if (p.defaultMonthlyLimitUsd > p.maxMonthlyLimitUsd) revert InvalidInput();
        if (p.defaultDailyLimitUsd > p.defaultMonthlyLimitUsd) revert InvalidInput();

        if (p.targetLtvBps == 0 || p.targetLtvBps > MAX_TARGET_LTV_BPS) revert InvalidInput();
        if (p.closeFactorBps == 0 || p.closeFactorBps > MAX_BPS) revert InvalidInput();
        if (p.maxAdjustmentBps > MAX_BPS) revert InvalidInput();
        // Capped below WAD, not at it: at WAD the grace period has no band left to apply in.
        if (p.graceFloorHf > MAX_GRACE_FLOOR_HF) revert InvalidInput();

        // A grace window longer than the window in which a user could react to a parameter change
        // would make the parameter delay meaningless.
        if (p.paramChangeDelay < p.liquidationGracePeriod) revert InvalidInput();

        if (
            p.modeDelay > MAX_DELAY || p.limitRaiseDelay > MAX_DELAY || p.collateralWithdrawDelay > MAX_DELAY
                || p.liquidationGracePeriod > MAX_DELAY || p.paramChangeDelay > MAX_DELAY || p.limitWaiveDelay > MAX_DELAY
        ) revert InvalidInput();

        // Floors, because `setParams` has no delay of its own.
        if (p.liquidationGracePeriod < MIN_LIQUIDATION_GRACE) revert InvalidInput();
        if (p.collateralWithdrawDelay < MIN_COLLATERAL_WITHDRAW_DELAY) revert InvalidInput();

        if (p.paramChangeDelay < currentParamChangeDelay) revert InvalidInput();
    }

    // ========================================= BOUNDED READS =========================================
    // Not configuration, but here for the same reason: both `SolidCashModuleV2` and its setters half
    // need them, and a copy in each is a copy neither has the EIP-170 budget for.

    /**
     * @notice This module's ceiling for a token as of now.
     * @dev `maxPriceUsd` quoted at `ceilingAnchor`, drifting upward at `ceilingGrowthPerSec`. Zero
     *      growth is a static ceiling, which is right for anything not expected to appreciate — and
     *      wrong for a yield-bearing share, where a static ceiling is an outage with a computable
     *      date.
     */
    function effectiveCeiling(TokenConfig storage cfg) public view returns (uint256) {
        uint256 growth = cfg.ceilingGrowthPerSec;
        if (growth == 0 || block.timestamp <= cfg.ceilingAnchor) return cfg.maxPriceUsd;
        return uint256(cfg.maxPriceUsd) + (growth * (block.timestamp - cfg.ceilingAnchor)) / WAD;
    }

    /**
     * @notice Reads the price provider under a gas cap, treating any failure as "unpriceable".
     * @dev A raw `staticcall` rather than `try/catch`, for the same two reasons the provider itself
     *      uses one for adapters: `try/catch` forwards all remaining gas, and it does not catch a
     *      failure to *decode* the return data — so an address with no code, which succeeds and
     *      returns nothing, propagates a decode revert straight past the `catch`.
     *
     *      A revert here would not stay here. It reaches `_positionValue`, which walks every
     *      allowlisted token, and through the lens that means one bad feed declines every card
     *      transaction for every user.
     */
    function readProvider(address provider, address token)
        public
        view
        returns (uint256 price, uint64 updatedAt, bool ok)
    {
        (bool success, bytes memory ret) = provider.staticcall{gas: PROVIDER_GAS_LIMIT}(
            abi.encodeWithSelector(ISolidPriceProviderV2.priceUsdDetailed.selector, token)
        );
        // A well-formed `(uint256, bool, uint64)` return is exactly three words.
        if (!success || ret.length != 96) return (0, 0, false);
        (price, ok, updatedAt) = abi.decode(ret, (uint256, bool, uint64));
    }

    /**
     * @notice Whether `module` is enabled on `safe`, reported as false for any address that cannot
     *         answer the question.
     * @dev Deliberately a raw `staticcall`. Solidity's `try/catch` catches reverts but not failures
     *      decoding the return data, so a call to an address with no code — which succeeds and
     *      returns nothing — propagates a decode revert straight past the `catch`. Solid Safes are
     *      ERC-4337 accounts that may be counterfactual, so that is a live case, and reverting would
     *      take down the lens' single authorize read instead of producing a clean decline.
     *
     *      The write paths intentionally do not use this: there, an unanswerable Safe must abort
     *      rather than be silently treated as revoked.
     */
    function tolerantIsModuleEnabled(address safe, address module) public view returns (bool) {
        (bool ok, bytes memory ret) = safe.staticcall(abi.encodeWithSelector(ISafe.isModuleEnabled.selector, module));
        if (!ok || ret.length != 32) return false;

        // Compared raw rather than through `abi.decode(ret, (bool))`, which reverts on any word
        // other than 0 or 1. The callee is the user's own account, so decoding here would hand a
        // non-conforming Safe the ability to turn this deliberately tolerant read into a revert —
        // and through the lens, into a declined card transaction for everyone.
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return word == 1;
    }
}
