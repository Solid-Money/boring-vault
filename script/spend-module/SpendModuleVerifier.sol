// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {SolidCashLens} from "src/spend-module/SolidCashLens.sol";
import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";
import {PriceFeedConfig} from "src/spend-module/interfaces/ISolidPriceProvider.sol";

import {SpendModuleConfig} from "./SpendModuleConfig.sol";

/**
 * @title SpendModuleVerifier
 * @notice Post-deployment read-back checks, shared by the deploy script and the standalone verifier.
 * @dev Covers the wiring that is immutable or expensive to undo, plus three things no single contract
 *      enforces and which are therefore the ones worth asserting mechanically:
 *
 *        1. **The spender cannot widen its own bounds.** `requiresAuth` is uniform across `spend`, the
 *           guardian functions and every `set*`, so the documented role separation exists only in the
 *           authority's capability table. Nothing in the module would stop a spender that had been
 *           granted `setOrgCaps`.
 *        2. **No role can call the inherited `transferOwnership`.** It comes from solmate's `Auth`
 *           under `requiresAuth` and remains live, so a role granted that selector could seize the
 *           module outright.
 *        3. **`lens.availableToSpend` does not revert.** That single `eth_call` is the whole authorize
 *           path, and its per-token `balanceOf` and `priceUsd` reads are unguarded - one bad
 *           allowlisted asset declines every user's card, not only the holder's.
 *
 *      Failures are counted and reported together, then revert at the end, so one run surfaces
 *      everything wrong instead of one thing at a time.
 *
 *      Context lives in storage and the checks are split across functions because the whole suite in
 *      one frame exceeds the EVM's addressable stack depth - the same constraint that forced
 *      `SolidCashModule.canSpend` to be split.
 */
abstract contract SpendModuleVerifier is SpendModuleConfig {
    struct VerifyContext {
        SolidPriceProvider provider;
        FuseRolesAuthority authority;
        SolidCashModule module;
        SolidCashLens lens;
        address treasury;
        address spender;
        address guardian;
        address finalOwner;
        address priceAdmin;
    }

    VerifyContext internal ctx;
    uint256 private _failures;

    function _check(bool ok, string memory label) private {
        console.log(ok ? "  PASS  " : "  FAIL  ", label);
        if (!ok) _failures++;
    }

    function verify(VerifyContext memory context) internal {
        ctx = context;
        _failures = 0;

        console.log("\n=== Verification ===");
        _verifyWiring();
        _verifyPricingAndAllowlist();
        _verifyCaps();
        _verifyRoles();
        _verifyOwnership();
        _verifyAuthorizeRead();
        _summarize();
    }

    function _verifyWiring() private {
        console.log("\nWiring:");
        _check(address(ctx.lens.module()) == address(ctx.module), "lens.module == SolidCashModule");
        _check(
            address(ctx.module.priceProvider()) == address(ctx.provider), "module.priceProvider == SolidPriceProvider"
        );
        _check(address(ctx.module.authority()) == address(ctx.authority), "module.authority == FuseRolesAuthority");
        _check(ctx.module.settlementTreasury() == ctx.treasury, "module.settlementTreasury matches (IMMUTABLE)");
        _check(address(ctx.module.priceProvider()).code.length > 0, "module.priceProvider has code");

        // The treasury receives every settlement, so if it were registered the balance-delta check in
        // `_settleToken` would be trivially satisfiable. The contract blocks it at registration.
        _check(!ctx.module.isRegistered(ctx.treasury), "settlement treasury is not a registered Safe");
    }

    function _verifyPricingAndAllowlist() private {
        console.log("\nPricing:");
        (address[] memory feedTokens,) = priceFeeds();
        for (uint256 i = 0; i < feedTokens.length; ++i) {
            (, bool usable) = ctx.provider.priceUsd(feedTokens[i]);
            _check(usable, "provider prices feed token");
        }

        console.log("\nAllowlist:");
        SpendTokenParams[] memory expected = spendTokens();
        address[] memory allowed = ctx.module.allowedTokens();
        _check(allowed.length == expected.length, "allowlist size matches spendTokens()");

        for (uint256 i = 0; i < expected.length; ++i) {
            SpendTokenParams memory t = expected[i];

            // Through the module, so its own band is applied - this is what `spend` would use, and it
            // is the check that catches a provider price the module will reject at settlement time.
            (uint256 price, bool moduleUsable) = ctx.module.getPriceUsd(t.token);
            _check(moduleUsable, string.concat("module accepts ", t.label, " price (own band applied)"));
            logUsd(string.concat("        ", t.label), price);

            (bool tokenAllowed, uint8 tokenDecimals,, uint96 minPrice, uint96 maxPrice) =
                ctx.module.spendTokenConfig(t.token);
            _check(tokenAllowed, string.concat(t.label, " is allowlisted in the module"));
            _check(
                minPrice == t.minPriceUsd && maxPrice == t.maxPriceUsd,
                string.concat(t.label, " band matches config")
            );
            _check(minPrice > 0, string.concat(t.label, " has a non-zero price floor"));

            // The module caches decimals at allowlist time and never cross-checks the provider's,
            // despite the shared `TokenDecimalsMismatch` error name.
            PriceFeedConfig memory feed = ctx.provider.getConfig(t.token);
            _check(
                feed.tokenDecimals == tokenDecimals,
                string.concat("module and provider agree on ", t.label, " decimals")
            );

            // The module band is the defence against a hostile provider upgrade, so it should be at
            // least as tight as the provider's own.
            _check(
                minPrice >= feed.minPriceUsd && maxPrice <= feed.maxPriceUsd,
                string.concat(t.label, " module band is no wider than the provider band")
            );
        }
    }

    function _verifyCaps() private {
        console.log("\nCaps:");
        SolidCashModule module = ctx.module;
        _check(module.maxPerTxUsd() > 0, "maxPerTxUsd is set");
        _check(module.maxDailyLimitUsd() > 0, "maxDailyLimitUsd is set");
        // The daily limit is meant to be the only cap a cardholder meets. A per-transaction cap
        // below the daily ceiling silently reintroduces a second one, and the UI no longer shows it
        // unless it binds - so catch it here rather than in a decline at the till.
        _check(
            module.maxPerTxUsd() >= module.maxDailyLimitUsd(),
            "maxPerTx >= maxDaily (per-transaction cap must not bind before the daily limit)"
        );
        _check(module.maxDailyLimitUsd() <= module.maxMonthlyLimitUsd(), "maxDaily <= maxMonthly");
        _check(
            module.defaultDailyLimitUsd() <= module.maxDailyLimitUsd(),
            "defaultDaily <= maxDaily (registerSafe would revert otherwise)"
        );
        _check(
            module.defaultMonthlyLimitUsd() <= module.maxMonthlyLimitUsd(),
            "defaultMonthly <= maxMonthly (registerSafe would revert otherwise)"
        );
        _check(module.limitRaiseDelay() > 0, "limitRaiseDelay is non-zero");
        _check(!module.isPaused(), "module is not paused");
    }

    function _verifyRoles() private {
        console.log("\nRoles:");
        FuseRolesAuthority authority = ctx.authority;
        address module = address(ctx.module);

        _check(
            authority.doesRoleHaveCapability(SPENDER_ROLE, module, SolidCashModule.spend.selector),
            "SPENDER_ROLE may call spend"
        );
        _check(authority.doesUserHaveRole(ctx.spender, SPENDER_ROLE), "spender key holds SPENDER_ROLE");
        _check(authority.doesUserHaveRole(ctx.guardian, GUARDIAN_ROLE), "guardian key holds GUARDIAN_ROLE");
        _check(
            authority.doesRoleHaveCapability(GUARDIAN_ROLE, module, SolidCashModule.pause.selector),
            "GUARDIAN_ROLE may call pause"
        );

        // The spender must not be able to widen its own bounds.
        _check(
            !authority.doesRoleHaveCapability(SPENDER_ROLE, module, SolidCashModule.setOrgCaps.selector),
            "SPENDER_ROLE may NOT call setOrgCaps"
        );
        _check(
            !authority.doesRoleHaveCapability(SPENDER_ROLE, module, SolidCashModule.allowSpendToken.selector),
            "SPENDER_ROLE may NOT call allowSpendToken"
        );
        _check(
            !authority.doesRoleHaveCapability(SPENDER_ROLE, module, SolidCashModule.setPriceProvider.selector),
            "SPENDER_ROLE may NOT call setPriceProvider"
        );
        _check(
            !authority.doesRoleHaveCapability(SPENDER_ROLE, module, SolidCashModule.setDefaultLimits.selector),
            "SPENDER_ROLE may NOT call setDefaultLimits"
        );
        _check(
            !authority.doesRoleHaveCapability(GUARDIAN_ROLE, module, SolidCashModule.spend.selector),
            "GUARDIAN_ROLE may NOT call spend"
        );

        // Inherited from solmate Auth and still live; `transferOwnership` is requiresAuth, so a role
        // granted that selector could seize the module outright.
        bytes4 transferOwnershipSel = bytes4(keccak256("transferOwnership(address)"));
        bytes4 setAuthoritySel = bytes4(keccak256("setAuthority(address)"));
        _check(
            !authority.doesRoleHaveCapability(SPENDER_ROLE, module, transferOwnershipSel)
                && !authority.doesRoleHaveCapability(GUARDIAN_ROLE, module, transferOwnershipSel),
            "no role may call transferOwnership"
        );
        _check(
            !authority.doesRoleHaveCapability(SPENDER_ROLE, module, setAuthoritySel)
                && !authority.doesRoleHaveCapability(GUARDIAN_ROLE, module, setAuthoritySel),
            "no role may call setAuthority"
        );
        _check(
            !authority.isCapabilityPublic(module, SolidCashModule.spend.selector), "spend is not a public capability"
        );
    }

    function _verifyOwnership() private {
        console.log("\nOwnership:");
        _check(ctx.module.owner() == ctx.finalOwner, "module.owner is the configured owner");
        _check(ctx.authority.owner() == ctx.finalOwner, "authority.owner is the configured owner");

        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        bytes32 PRICE_ADMIN_ROLE = keccak256("PRICE_ADMIN_ROLE");
        bytes32 UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

        SolidPriceProvider provider = ctx.provider;
        _check(provider.hasRole(DEFAULT_ADMIN_ROLE, ctx.finalOwner), "owner holds provider DEFAULT_ADMIN_ROLE");
        _check(provider.hasRole(UPGRADER_ROLE, ctx.finalOwner), "owner holds provider UPGRADER_ROLE");
        _check(provider.hasRole(PRICE_ADMIN_ROLE, ctx.priceAdmin), "price admin holds PRICE_ADMIN_ROLE");
        _check(
            !provider.hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || msg.sender == ctx.finalOwner,
            "deployer no longer holds provider DEFAULT_ADMIN_ROLE"
        );
        _check(
            !provider.hasRole(UPGRADER_ROLE, msg.sender) || msg.sender == ctx.finalOwner,
            "deployer no longer holds provider UPGRADER_ROLE"
        );
    }

    /**
     * @dev The premise of the lens is one `eth_call` that answers inside ~300ms and does not revert.
     *      Exercise it against an address with no code - the counterfactual-Safe case, which must
     *      decline cleanly rather than throw.
     */
    function _verifyAuthorizeRead() private {
        console.log("\nAuthorize read:");
        uint256 gasBefore = gasleft();
        try ctx.lens.availableToSpend(address(0xdEaD)) returns (SolidCashLens.SpendAvailability memory data) {
            uint256 gasUsed = gasBefore - gasleft();
            _check(true, "availableToSpend does not revert for a codeless address");
            _check(!data.moduleEnabled, "codeless address reports moduleEnabled=false");
            _check(data.spendableUsd == 0, "codeless address reports spendableUsd=0");
            _check(data.perTokenBreakdown.length == ctx.module.allowedTokens().length, "breakdown covers allowlist");
            _check(!data.anyPriceUnusable, "no allowlisted asset is unpriceable");
            _check(data.blockNumber > 0, "blockNumber populated (in-flight subtraction anchor)");
            console.log("  INFO   availableToSpend gas:", gasUsed);
        } catch {
            _check(false, "availableToSpend REVERTED");
        }
    }

    function _summarize() private view {
        console.log("\n=== Addresses ===");
        console.log("SolidPriceProvider:", address(ctx.provider));
        console.log("FuseRolesAuthority:", address(ctx.authority));
        console.log("SolidCashModule:   ", address(ctx.module));
        console.log("SolidCashLens:     ", address(ctx.lens));
        console.log("SettlementTreasury:", ctx.treasury);

        if (_failures > 0) {
            console.log("\nFAILURES:", _failures);
            revert("spend module verification failed");
        }
        console.log("\nAll checks passed.");
    }
}
