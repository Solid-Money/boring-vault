// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {SolidLiquidator} from "src/spend-module/v2/SolidLiquidator.sol";
import {SolidSpendLens, UnifiedAvailability} from "src/spend-module/v2/SolidSpendLens.sol";
import {SolidPriceProviderV2} from "src/spend-module/v2/SolidPriceProviderV2.sol";
import {Params, TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";
import {PriceFeedConfigV2, PriceFeedKindV2} from "src/spend-module/v2/interfaces/ISolidPriceProviderV2.sol";

import {SpendModuleV2Config} from "./SpendModuleV2Config.sol";

/// @dev The slice of the live v1 module the verifier reads, to prove the provider upgrade did not
///      break the cohort that is still on it.
interface ISolidCashModuleV1Read {
    function allowedTokens() external view returns (address[] memory);
    function getPriceUsd(address token) external view returns (uint256, bool);
    function priceProvider() external view returns (address);
}

/**
 * @title SpendModuleV2Verifier
 * @notice Read-back checks shared by the deploy script and the standalone verifier.
 * @dev Everything here is asserted rather than logged, so a bad deployment fails the run that
 *      produced it instead of being discovered later.
 *
 *      Three of these checks exist because no single contract can enforce them:
 *
 *        - **The role table.** `requiresAuth` on the module is uniform across `spend`,
 *          `spendCredit`, the guardian functions and every `set*`, so the entire documented role
 *          separation lives in the authority's capability table and nowhere else. A spender that
 *          could reach `setParams` could widen its own bounds.
 *        - **The two halves agree.** `setSettersImpl` checks the immutables at wiring time; this
 *          re-checks them from the outside, because a `delegatecall` into a setters half built with
 *          a different treasury would read that half's copy.
 *        - **v1 still prices.** The provider is shared, and v2's deployment upgrades it underneath a
 *          live v1 module serving real cardholders.
 */
abstract contract SpendModuleV2Verifier is SpendModuleV2Config {
    struct VerifyContext {
        SolidPriceProviderV2 provider;
        RolesAuthority authority;
        SolidCashModuleV2 core;
        address setters;
        SolidSpendLens lens;
        address v1Module;
        address treasury;
        address spender;
        address creditSpender;
        address guardian;
        address liquidator;
        address liquidationOperator;
        address finalOwner;
    }

    /**
     * @param rolesConfigured Whether step D has landed. When it has not, the role table is reported
     *        as outstanding rather than asserted — the authority is v1's and already owned by the
     *        multisig, so a fresh deploy cannot grant on it and failing here would only hide the
     *        rest of the verification behind a known-pending step.
     */
    function verify(VerifyContext memory c, bool rolesConfigured) internal view {
        console.log("\n=== verification ===");
        _verifyWiring(c);
        _verifyParams(c);
        _verifyTokens(c);
        _verifyLiquidator(c);
        if (rolesConfigured) _verifyRoles(c);
        else _printRolesOutstanding();
        _verifyOwnership(c);
        _verifyLegacyCohort(c);
        _verifyLens(c);
        _verifySeal(c);
        console.log("\nAll checks passed.");
    }

    // ========================================= WIRING =========================================

    function _verifyWiring(VerifyContext memory c) private view {
        require(c.core.settersImpl() == c.setters, "settersImpl not wired");
        require(c.core.settlementTreasury() == c.treasury, "core treasury mismatch");
        require(c.core.v1Module() == c.v1Module, "core v1Module mismatch");
        require(address(c.core.priceProvider()) == address(c.provider), "core priceProvider mismatch");

        // Read from the setters' OWN storage, i.e. a direct call rather than through the fallback.
        // Immutables are baked into each contract's bytecode, so a `delegatecall` into the setters
        // reads the setters' copies — which is the whole reason `setSettersImpl` compares them.
        require(
            SolidCashModuleV2Setters(c.setters).settlementTreasury() == c.treasury, "setters treasury mismatch"
        );
        require(SolidCashModuleV2Setters(c.setters).v1Module() == c.v1Module, "setters v1Module mismatch");

        require(!c.core.isPaused(), "module deployed paused");
        require(!c.core.liquidationsPaused(), "liquidations deployed paused");
        require(c.core.interestIndex() >= WAD, "interest index not seeded");
        require(c.core.lastAccrualTimestamp() != 0, "accrual timestamp not seeded");

        require(address(c.lens.v2()) == address(c.core), "lens points at the wrong core");
        require(address(c.lens.v1()) == c.v1Module, "lens points at the wrong v1 module");

        console.log("  wiring                ok");
    }

    // ========================================= PARAMS =========================================

    function _verifyParams(VerifyContext memory c) private view {
        Params memory want = params();
        Params memory got = SolidCashModuleV2Setters(address(c.core)).getParams();

        require(got.maxPerTxUsd == want.maxPerTxUsd, "maxPerTxUsd");
        require(got.maxDailyLimitUsd == want.maxDailyLimitUsd, "maxDailyLimitUsd");
        require(got.maxMonthlyLimitUsd == want.maxMonthlyLimitUsd, "maxMonthlyLimitUsd");
        require(got.defaultDailyLimitUsd == want.defaultDailyLimitUsd, "defaultDailyLimitUsd");
        require(got.defaultMonthlyLimitUsd == want.defaultMonthlyLimitUsd, "defaultMonthlyLimitUsd");
        require(got.maxDebtPerSafeUsd == want.maxDebtPerSafeUsd, "maxDebtPerSafeUsd");
        require(got.maxGlobalDebtUsd == want.maxGlobalDebtUsd, "maxGlobalDebtUsd");
        require(got.maxForcedSpendUsd == want.maxForcedSpendUsd, "maxForcedSpendUsd");
        require(got.minPositionUsd == want.minPositionUsd, "minPositionUsd");
        require(got.targetLtvBps == want.targetLtvBps, "targetLtvBps");
        require(got.closeFactorBps == want.closeFactorBps, "closeFactorBps");
        require(got.maxAdjustmentBps == want.maxAdjustmentBps, "maxAdjustmentBps");
        require(got.modeDelay == want.modeDelay, "modeDelay");
        require(got.limitRaiseDelay == want.limitRaiseDelay, "limitRaiseDelay");
        require(got.collateralWithdrawDelay == want.collateralWithdrawDelay, "collateralWithdrawDelay");
        require(got.liquidationGracePeriod == want.liquidationGracePeriod, "liquidationGracePeriod");
        require(got.graceFloorHf == want.graceFloorHf, "graceFloorHf");
        require(got.paramChangeDelay == want.paramChangeDelay, "paramChangeDelay");
        require(got.limitWaiveDelay == want.limitWaiveDelay, "limitWaiveDelay");

        // Not a bound the contract enforces, but the one the app depends on: solid-ui filters a daily
        // preset out unless `daily * MONTHLY_LIMIT_MULTIPLIER <= maxMonthlyLimitUsd`, so a monthly
        // ceiling below that multiple makes the top presets vanish from the picker with no error.
        require(
            got.maxMonthlyLimitUsd >= got.maxDailyLimitUsd * MONTHLY_LIMIT_MULTIPLIER,
            "monthly ceiling below the app's daily multiple - top presets would disappear"
        );

        // The grace period is the window in which a user can repay and ops can reverse a booking
        // that should not have existed — and a forced booking never takes the `graceFloorHf`
        // shortcut, so it is also the minimum time between a compromised credit-spender key
        // creating unbacked debt and anyone being able to act on it.
        require(got.liquidationGracePeriod >= 1 days, "liquidation grace below the 1 day launch decision");
        // Enforced by `validateParams` too; asserted here because the relationship is the reason the
        // parameter delay is a day, and a future `setParams` should not be able to make it look
        // accidental.
        require(got.paramChangeDelay >= got.liquidationGracePeriod, "paramChangeDelay below the grace period");
        // At WAD the shortcut swallows every unhealthy position and the grace period has no band
        // left to apply in.
        require(got.graceFloorHf < WAD, "graceFloorHf at WAD disables the grace period entirely");

        console.log("  params                ok");
        if (got.modeDelay == 0) console.log("    note: modeDelay = 0, switching into Credit is immediate");
        if (got.limitRaiseDelay == 0) console.log("    note: limitRaiseDelay = 0, raises apply immediately");
        if (c.core.borrowApyPerSecond() == 0) console.log("    note: borrow APY = 0, credit accrues no interest");
        require(c.core.borrowApyPerSecond() == BORROW_APY_PER_SECOND, "borrowApyPerSecond does not match config");
    }

    // ========================================= TOKENS =========================================

    function _verifyTokens(VerifyContext memory c) private view {
        address[] memory allowed = c.core.allowedTokens();
        require(allowed.length == 3, "unexpected allowlist size");

        for (uint256 i = 0; i < allowed.length; ++i) {
            address token = allowed[i];
            TokenConfig memory cfg = SolidCashModuleV2Setters(address(c.core)).getTokenConfig(token);

            require(cfg.tokenDecimals == ERC20(token).decimals(), "token decimals disagree");
            require(!c.core.tokenPaused(token), "token deployed paused");

            // Priceable, strictly in band, and usable — a token allowlisted while unpriceable is a
            // silent understatement of every holder's power and reverts every spend that touches it.
            (uint256 price, bool usable, bool inBand) = c.core.getPriceUsd(token);
            require(usable, "allowlisted token is not priceable");
            require(inBand, "allowlisted token prices outside its own band at deploy");
            logUsd(string.concat("    price ", vm.toString(token)), price);

            // The module's band must sit INSIDE the provider's, or the module is not a second layer.
            PriceFeedConfigV2 memory feed = c.provider.getConfig(token);
            require(feed.kind != PriceFeedKindV2.NONE, "allowlisted token has no feed");
            require(feed.tokenDecimals == cfg.tokenDecimals, "provider and module decimals disagree");
            require(cfg.minPriceUsd >= feed.minPriceUsd, "module floor below the provider's");
            require(cfg.maxPriceUsd <= feed.maxPriceUsd, "module ceiling above the provider's");
            require(
                cfg.minPriceUsd != feed.minPriceUsd || cfg.maxPriceUsd != feed.maxPriceUsd,
                "module and provider bands are identical - that is one layer, not two"
            );

            if (cfg.collateral) {
                require(cfg.liquidationThreshold > cfg.ltv, "threshold at or below ltv");
                require(
                    uint256(cfg.liquidationThreshold) + (uint256(cfg.liquidationBonusBps) * WAD) / MAX_BPS <= WAD,
                    "threshold + bonus exceeds 100%"
                );
            }

            if (cfg.ceilingGrowthPerSec != 0) {
                require(cfg.ceilingAnchor != 0, "drifting ceiling with no anchor");
                require(cfg.ceilingAnchor <= block.timestamp, "ceiling anchored in the future");
            } else if (cfg.maxStalenessSeconds != 0 && feed.kind == PriceFeedKindV2.VEDA_ACCOUNTANT) {
                // Not fatal, but it is the finding that produced the drift in the first place.
                console.log("    WARNING: appreciating asset on a STATIC ceiling", token);
            }
        }

        // ---- tender ----
        //
        // Strictly narrower than spendable. `_sizeRepay` uses a token's price to decide how much
        // DEBT an incoming payment retires, so a bare uncorroborated peg accepted as tender lets a
        // borrower settle a dollar of debt with a token that has stopped being worth a dollar.
        (address[] memory tender,) = repayTenderTokens();
        for (uint256 i = 0; i < tender.length; ++i) {
            require(c.core.repayTender(tender[i]), "configured tender token is not set on the module");
        }

        uint256 tenderCount;
        for (uint256 i = 0; i < allowed.length; ++i) {
            if (!c.core.repayTender(allowed[i])) continue;
            ++tenderCount;

            // A tender token must be one whose price this system already relies on elsewhere.
            // In practice that means soUSD (accountant-priced) and the accountant's own base asset.
            bool expected;
            for (uint256 j = 0; j < tender.length; ++j) {
                if (tender[j] == allowed[i]) {
                    expected = true;
                    break;
                }
            }
            require(expected, "a token is tender that the config does not list - review before launch");
        }
        require(tenderCount == tender.length, "tender set on chain does not match the config");

        console.log("  tokens                ok");
        console.log("    tender tokens:", tenderCount, "of", allowed.length);
    }

    // ========================================= ROLES =========================================

    /**
     * @dev The capability table is the only place the role separation exists, so it is asserted in
     *      both directions: what each key can reach, and — more importantly — what it cannot.
     *
     *      **One address may hold both spender roles.** The roles are what is permanent here, since
     *      the module is not upgradeable; the key assignment is a grant on the shared authority and
     *      is reversible at any time. When the two are merged, the cross-role exclusions below are
     *      vacuous by construction and are skipped — but every exclusion that bounds the *union*
     *      still has to hold, and those are asserted unconditionally. That is the real invariant:
     *      no spender key, merged or not, may reach configuration, the limit waiver, or
     *      `setSettersImpl`.
     */
    function _verifyRoles(VerifyContext memory c) private view {
        address core = address(c.core);
        bool mergedSpenders = c.spender == c.creditSpender;

        // The debit spender reaches `spend`.
        _can(c, c.spender, core, SolidCashModuleV2.spend.selector, "spender -> spend");
        if (!mergedSpenders) {
            _cannot(c, c.spender, core, SolidCashModuleV2.spendCredit.selector, "spender must NOT reach spendCredit");
            _cannot(
                c, c.spender, core, SolidCashModuleV2.bookForcedSpend.selector, "spender must NOT reach bookForcedSpend"
            );
        }
        _cannot(c, c.spender, core, SolidCashModuleV2Setters.setParams.selector, "spender must NOT reach setParams");
        _cannot(c, c.spender, core, SolidCashModuleV2Setters.allowToken.selector, "spender must NOT reach allowToken");

        // The credit spender reaches the credit ledger and the arrears paths, and not `spend`.
        _can(c, c.creditSpender, core, SolidCashModuleV2.spendCredit.selector, "creditSpender -> spendCredit");
        _can(c, c.creditSpender, core, SolidCashModuleV2.bookForcedSpend.selector, "creditSpender -> bookForcedSpend");
        _can(
            c, c.creditSpender, core, SolidCashModuleV2.adjustBookedSpend.selector, "creditSpender -> adjustBookedSpend"
        );
        _can(c, c.creditSpender, core, SolidCashModuleV2.reverseSpend.selector, "creditSpender -> reverseSpend");

        // The backend may never spend a user's balance or unwind their collateral on their behalf.
        // `_requireSafeOrCreditSpender` still lets the SAFE call both, so self-service repayment is
        // unaffected; what is asserted here is that no key of Solid's can.
        _cannot(
            c,
            c.creditSpender,
            core,
            SolidCashModuleV2Setters.repayFromSafe.selector,
            "creditSpender must NOT reach repayFromSafe"
        );
        _cannot(
            c,
            c.creditSpender,
            core,
            SolidCashModuleV2Setters.repayFromCollateral.selector,
            "creditSpender must NOT reach repayFromCollateral"
        );
        _cannot(
            c, c.spender, core, SolidCashModuleV2Setters.repayFromSafe.selector, "spender must NOT reach repayFromSafe"
        );
        _cannot(
            c,
            c.spender,
            core,
            SolidCashModuleV2Setters.repayFromCollateral.selector,
            "spender must NOT reach repayFromCollateral"
        );
        if (!mergedSpenders) {
            _cannot(c, c.creditSpender, core, SolidCashModuleV2.spend.selector, "creditSpender must NOT reach spend");
        }
        _cannot(
            c, c.creditSpender, core, SolidCashModuleV2Setters.setParams.selector, "creditSpender must NOT reach setParams"
        );
        _cannot(
            c,
            c.creditSpender,
            core,
            SolidCashModuleV2Setters.requestWaiveSafeLimits.selector,
            "creditSpender must NOT reach the limit waiver"
        );

        // The guardian reaches all three breakers and no configuration.
        _can(c, c.guardian, core, SolidCashModuleV2Setters.pause.selector, "guardian -> pause");
        _can(c, c.guardian, core, SolidCashModuleV2Setters.unpause.selector, "guardian -> unpause");
        _can(c, c.guardian, core, SolidCashModuleV2Setters.setSafePaused.selector, "guardian -> setSafePaused");
        _can(c, c.guardian, core, SolidCashModuleV2Setters.setTokenPaused.selector, "guardian -> setTokenPaused");
        _can(
            c,
            c.guardian,
            core,
            SolidCashModuleV2Setters.setLiquidationsPaused.selector,
            "guardian -> setLiquidationsPaused"
        );
        _cannot(c, c.guardian, core, SolidCashModuleV2Setters.setParams.selector, "guardian must NOT reach setParams");
        _cannot(c, c.guardian, core, SolidCashModuleV2.spend.selector, "guardian must NOT reach spend");

        // Nobody but the owner reaches the upgrade hatch, and the owner reaches it directly rather
        // than through the authority — `setSettersImpl` is not `requiresAuth`, so no grant can open
        // it however the table is configured. Asserted anyway, because a grant here would be a
        // misunderstanding worth catching.
        _cannot(
            c, c.spender, core, SolidCashModuleV2.setSettersImpl.selector, "no role may reach setSettersImpl (spender)"
        );
        _cannot(
            c,
            c.creditSpender,
            core,
            SolidCashModuleV2.setSettersImpl.selector,
            "no role may reach setSettersImpl (creditSpender)"
        );
        _cannot(
            c, c.guardian, core, SolidCashModuleV2.setSettersImpl.selector, "no role may reach setSettersImpl (guardian)"
        );

        // Ownership is owner-only in this module (both `transferOwnership` and `setAuthority` are
        // overridden off `requiresAuth`), so no grant can reach them. A grant here would mean a role
        // could become the owner and then replace the setters half before the seal — which is the
        // whole module, including every escrowed balance.
        // Written as literal selectors because both are inherited from solmate's `Auth` and
        // overridden in `SolidCashStorageV2`, which puts them out of reach of
        // `SolidCashModuleV2.<fn>.selector`.
        _cannot(
            c,
            c.creditSpender,
            core,
            bytes4(keccak256("transferOwnership(address)")),
            "no role may reach transferOwnership"
        );
        _cannot(
            c, c.creditSpender, core, bytes4(keccak256("setAuthority(address)")), "no role may reach setAuthority"
        );

        // ---- liquidation, the two-key split ----
        //
        // `liquidate` is no longer permissionless, because `bookForcedSpend` can create debt with no
        // collateral behind it and the two composed into a complete theft. What must hold:
        //   1. the LIQUIDATOR role reaches it, and the holder is the CONTRACT;
        //   2. no spender key reaches it, on the module OR through the liquidator contract.
        _can(c, c.liquidator, core, SolidCashModuleV2.liquidate.selector, "SolidLiquidator -> core.liquidate");
        _cannot(c, c.spender, core, SolidCashModuleV2.liquidate.selector, "spender must NOT reach liquidate");
        _cannot(
            c, c.creditSpender, core, SolidCashModuleV2.liquidate.selector, "creditSpender must NOT reach liquidate"
        );

        _can(
            c,
            c.liquidationOperator,
            c.liquidator,
            SolidLiquidator.liquidate.selector,
            "liquidationOperator -> SolidLiquidator.liquidate"
        );
        // The property the whole design rests on: manufacturing a liquidation needs TWO independent
        // compromises. One key holding both roles collapses it back to one.
        _cannot(
            c,
            c.creditSpender,
            c.liquidator,
            SolidLiquidator.liquidate.selector,
            "creditSpender must NOT drive SolidLiquidator - that is the second key"
        );

        console.log("  roles                 ok");
    }

    /**
     * @dev The liquidator contract's own invariants, independent of the role table.
     *
     *      Its value is that it cannot keep what it seizes, and that rests on two immutables and on
     *      there being no function that names a destination. Both are checked from outside.
     */
    function _verifyLiquidator(VerifyContext memory c) private view {
        require(c.liquidator != address(0), "SolidLiquidator not deployed");
        requireHasCode(c.liquidator, "SolidLiquidator");

        SolidLiquidator liq = SolidLiquidator(c.liquidator);
        require(liq.module() == address(c.core), "liquidator points at a different module");
        // The step that makes a seizure unprofitable for whoever triggers it: both legs converge on
        // the module's own immutable settlement destination.
        require(liq.settlementTreasury() == c.treasury, "liquidator treasury is not the module's");
        require(liq.settlementTreasury() == c.core.settlementTreasury(), "liquidator/core treasury disagree");
        require(liq.owner() == c.finalOwner, "liquidator owner not handed over");

        console.log("  liquidator            ok");
    }

    function _printRolesOutstanding() private pure {
        console.log("");
        console.log("  OUTSTANDING: the authority role table has not been granted for v2.");
        console.log("    Until it is, no key can call `spend` or `spendCredit` on the new module and");
        console.log("    the guardian cannot pause it. The grants are multisig transactions; the");
        console.log("    deploy script prints their calldata.");
    }

    function _can(VerifyContext memory c, address user, address target, bytes4 sig, string memory label)
        private
        view
    {
        require(c.authority.canCall(user, target, sig), label);
    }

    /// @dev Also asserts the key is not the owner, since `Auth.isAuthorized` short-circuits for the
    ///      owner and would make a "cannot" check vacuously pass.
    function _cannot(VerifyContext memory c, address user, address target, bytes4 sig, string memory label)
        private
        view
    {
        require(user != c.core.owner(), string.concat(label, " (key is the owner)"));
        require(!c.authority.canCall(user, target, sig), label);
    }

    // ========================================= OWNERSHIP =========================================

    function _verifyOwnership(VerifyContext memory c) private view {
        require(c.core.owner() == c.finalOwner, "core owner not handed over");
        require(c.authority.owner() == c.finalOwner, "authority owner not handed over");
        require(address(c.core.authority()) == address(c.authority), "core authority mismatch");

        require(
            c.provider.hasRole(c.provider.UPGRADER_ROLE(), c.finalOwner),
            "owner does not hold UPGRADER_ROLE on the provider"
        );

        console.log("  ownership             ok");
    }

    // ========================================= LEGACY COHORT =========================================

    /**
     * @dev The provider proxy is shared, and deploying v2 upgrades it underneath a live v1 module
     *      serving real cardholders. Every v1 asset must still price afterwards.
     *
     *      This is the check that catches the `STABLE` change: v2's `setTokenConfig` refuses to
     *      create a new bare peg, and the read path still honours the legacy ones — so the upgrade
     *      orphans nothing, and this proves it rather than assuming it. USDC.e is soUSD's accountant
     *      base, so anything that made it unpriceable would take soUSD down on BOTH modules.
     */
    function _verifyLegacyCohort(VerifyContext memory c) private view {
        ISolidCashModuleV1Read v1 = ISolidCashModuleV1Read(c.v1Module);

        require(v1.priceProvider() == address(c.provider), "v1 points at a different provider");

        address[] memory tokens = v1.allowedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            (, bool usable) = v1.getPriceUsd(tokens[i]);
            require(usable, "provider upgrade left a v1 token unpriceable");
        }

        console.log("  v1 cohort still prices ok");
    }

    // ========================================= LENS =========================================

    /**
     * @dev The authorize path's whole decision is one `eth_call` against this, inside a 300ms budget
     *      where a timeout is a decline. It has to answer for an address that is on neither module,
     *      which is the shape of every first-time lookup.
     */
    function _verifyLens(VerifyContext memory c) private view {
        UnifiedAvailability memory data = c.lens.availableToSpend(address(0xdead));
        require(data.cohort == c.lens.COHORT_NONE(), "unknown address did not report COHORT_NONE");
        require(data.blockNumber == block.number, "lens did not answer at this block");
        console.log("  lens                  ok");
    }

    // ========================================= SEAL =========================================

    function _verifySeal(VerifyContext memory c) private view {
        if (c.core.settersSealed()) {
            console.log("  setters               SEALED");
            return;
        }
        console.log("");
        console.log("  OUTSTANDING: the setters implementation is NOT sealed.");
        console.log("    Until it is, `setSettersImpl` is a delegatecall target that can replace the");
        console.log("    module's behaviour and move every escrowed token. It is owner-only and no");
        console.log("    role can be granted it, so the exposure is the owner multisig - but the");
        console.log("    contract documents itself as non-upgradeable, and that is only true after:");
        console.log("      forge script script/spend-module/v2/SealSettersV2.s.sol --rpc-url fuse --broadcast");
    }
}
