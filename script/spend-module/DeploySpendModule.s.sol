// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {Authority} from "@solmate/auth/Auth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {SolidCashLens} from "src/spend-module/SolidCashLens.sol";
import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";
import {PriceFeedConfig, PriceFeedKind} from "src/spend-module/interfaces/ISolidPriceProvider.sol";

import {SpendModuleVerifier} from "./SpendModuleVerifier.sol";

/**
 * @title DeploySpendModule
 * @notice Deploys and fully configures the card spend module in one run.
 * @dev Unlike the Hardhat chain in `scripts/spend-module/`, which is nine invocations because each is
 *      a separate process, this does the whole sequence in one script. That is the reason to prefer
 *      this path: the entire sequence can be rehearsed against a Fuse fork before any of it touches
 *      mainnet, and it either completes or reverts as a unit rather than stranding a half-configured
 *      module.
 *
 *      Rehearse (no broadcast, nothing recorded):
 *        forge script script/spend-module/DeploySpendModule.s.sol --fork-url $FUSE_RPC_URL -vvv
 *
 *      Deploy:
 *        forge script script/spend-module/DeploySpendModule.s.sol --rpc-url fuse --broadcast --slow -vvv
 *
 *      Required env: SPENDER, GUARDIAN, SETTLEMENT_TREASURY.
 *      Optional: OWNER, PRICE_ADMIN, EXISTING_AUTHORITY, SKIP_HANDOVER.
 *
 *      State is carried in a struct rather than locals because the full sequence otherwise exceeds
 *      the EVM's addressable stack depth.
 */
contract DeploySpendModule is SpendModuleVerifier {
    struct Deployment {
        address deployer;
        address finalOwner;
        address priceAdmin;
        address spender;
        address guardian;
        address treasury;
        SolidPriceProvider provider;
        address implementation;
        FuseRolesAuthority authority;
        SolidCashModule module;
        SolidCashLens lens;
    }

    Deployment internal d;

    function run() external {
        require(block.chainid == FUSE_CHAIN_ID, "phase 1 targets Fuse (122) only");

        _resolveKeys();

        vm.startBroadcast();
        _deployProvider();
        _configureFeeds();
        _deployAuthorityModuleAndLens();
        _configureRoles();
        _configureCaps();
        _maybeHandOver();
        vm.stopBroadcast();

        _record();

        // Same checks as VerifySpendModule.s.sol, run inline so a bad deployment fails this script
        // rather than being discovered later.
        verify(
            VerifyContext({
                provider: d.provider,
                authority: d.authority,
                module: d.module,
                lens: d.lens,
                treasury: d.treasury,
                spender: d.spender,
                guardian: d.guardian,
                finalOwner: d.finalOwner,
                priceAdmin: d.priceAdmin
            })
        );
    }

    /// @dev Resolved first so a missing key fails before any gas is spent.
    function _resolveKeys() private {
        d.deployer = msg.sender;
        d.finalOwner = owner();
        d.priceAdmin = priceAdmin();
        d.spender = spender();
        d.guardian = guardian();
        d.treasury = settlementTreasury();

        // Checked against every spend token, not just soUSD: `_settleToken` proves a transfer arrived
        // by the treasury's own balance delta, and a treasury that IS one of those token contracts
        // makes that check meaningless.
        SpendTokenParams[] memory tokens = spendTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(
                d.treasury != tokens[i].token,
                string.concat("settlementTreasury must not be a spend token (", tokens[i].label, ")")
            );
        }
        require(d.treasury != d.deployer, "settlementTreasury must not be the deployer");

        console.log("Deployer:           ", d.deployer);
        console.log("Final owner:        ", d.finalOwner);
        console.log("Price admin:        ", d.priceAdmin);
        console.log("Spender:            ", d.spender);
        console.log("Guardian:           ", d.guardian);
        console.log("Settlement treasury:", d.treasury, "<-- IMMUTABLE");

        if (d.priceAdmin == d.finalOwner) {
            console.log("");
            console.log("WARNING: PRICE_ADMIN_ROLE and UPGRADER_ROLE will both sit on the owner.");
            console.log("         Set PRICE_ADMIN to split feed configuration from upgrade authority.");
        }
    }

    /**
     * @dev Initialized with the *deployer* as admin so feeds can be configured in this same run, then
     *      handed over at the end. `initialize` grants DEFAULT_ADMIN, PRICE_ADMIN and UPGRADER
     *      together for a clean bootstrap, which is exactly why they must be split before going live.
     */
    function _deployProvider() private {
        console.log("\n[1/6] SolidPriceProvider");
        SolidPriceProvider implementation = new SolidPriceProvider();
        d.implementation = address(implementation);
        d.provider = SolidPriceProvider(
            address(new ERC1967Proxy(d.implementation, abi.encodeCall(SolidPriceProvider.initialize, (d.deployer))))
        );
        console.log("  implementation:", d.implementation);
        console.log("  proxy:         ", address(d.provider));
    }

    /**
     * @dev Order matters: a VEDA_ACCOUNTANT feed reverts with `BaseAssetNotConfigured` unless its base
     *      asset already has one, so USDC precedes soUSD (see `priceFeeds`). `setTokenConfig` validates the
     *      relationships that would otherwise silently misprice the asset - `vault()`, `base()` and
     *      both decimals fields - so a bad config reverts here rather than reaching production.
     */
    function _configureFeeds() private {
        console.log("\n[2/6] Price feeds");
        (address[] memory tokens, PriceFeedConfig[] memory configs) = priceFeeds();

        for (uint256 i = 0; i < tokens.length; ++i) {
            requireHasCode(tokens[i], "feed token");
            d.provider.setTokenConfig(tokens[i], configs[i]);

            (uint256 price, bool usable) = d.provider.priceUsd(tokens[i]);
            console.log("  token:", tokens[i]);
            logUsd("    price", price);
            require(usable, "feed configured but not usable - check accountant liveness");
        }
    }

    /**
     * @dev The authority is dedicated, not the vault's. `requiresAuth` on SolidCashModule is uniform
     *      across `spend`, the guardian functions and every `set*`, so the whole documented role
     *      separation lives in that contract's capability table and nowhere else - sharing the vault's
     *      authority would put the table under the vault owner's control.
     *
     *      `settlementTreasury` is immutable from here. The provider is effectively immutable too:
     *      `setPriceProvider` only checks for the zero address, so a provider that cannot answer
     *      `priceUsd` reverts every spend and every view until the owner corrects it - which is why
     *      the previous step proved it answers before we wire it in.
     */
    function _deployAuthorityModuleAndLens() private {
        console.log("\n[3/6] FuseRolesAuthority");
        if (existingAuthority() != address(0)) {
            requireHasCode(existingAuthority(), "existing authority");
            d.authority = FuseRolesAuthority(existingAuthority());
            console.log("  reusing:", address(d.authority));
        } else {
            d.authority = new FuseRolesAuthority(d.deployer, Authority(address(0)));
            console.log("  deployed:", address(d.authority));
        }

        console.log("\n[4/6] SolidCashModule");
        d.module = new SolidCashModule(d.deployer, address(d.authority), d.treasury, address(d.provider));
        console.log("  deployed:", address(d.module));

        console.log("\n[5/6] SolidCashLens");
        d.lens = new SolidCashLens(address(d.module));
        console.log("  deployed:", address(d.lens));
    }

    /**
     * @dev SPENDER_ROLE gets exactly `spend`. Nothing grants a configuration selector to any role, and
     *      nothing grants the inherited `transferOwnership` / `setAuthority` - a spender that could
     *      call `setOrgCaps` or `allowSpendToken` would be able to widen its own bounds.
     */
    function _configureRoles() private {
        console.log("\n[6/6] Roles, caps and allowlist");
        d.authority.setRoleCapability(SPENDER_ROLE, address(d.module), SolidCashModule.spend.selector, true);
        d.authority.setRoleCapability(GUARDIAN_ROLE, address(d.module), SolidCashModule.pause.selector, true);
        d.authority.setRoleCapability(GUARDIAN_ROLE, address(d.module), SolidCashModule.unpause.selector, true);
        d.authority.setRoleCapability(GUARDIAN_ROLE, address(d.module), SolidCashModule.setSafePaused.selector, true);
        d.authority.setUserRole(d.spender, SPENDER_ROLE, true);
        d.authority.setUserRole(d.guardian, GUARDIAN_ROLE, true);
        console.log("  SPENDER_ROLE  -> spend");
        console.log("  GUARDIAN_ROLE -> pause / unpause / setSafePaused");
    }

    /**
     * @dev Org ceilings before defaults: `registerSafe` checks a Safe's caps - chosen or defaulted -
     *      against the live ceilings, so a default above a ceiling makes every registration revert.
     */
    function _configureCaps() private {
        require(DEFAULT_DAILY_LIMIT_USD <= MAX_DAILY_LIMIT_USD, "default daily above org ceiling");
        require(DEFAULT_MONTHLY_LIMIT_USD <= MAX_MONTHLY_LIMIT_USD, "default monthly above org ceiling");

        d.module.setOrgCaps(MAX_PER_TX_USD, MAX_DAILY_LIMIT_USD, MAX_MONTHLY_LIMIT_USD);
        d.module.setDefaultLimits(DEFAULT_DAILY_LIMIT_USD, DEFAULT_MONTHLY_LIMIT_USD);
        d.module.setLimitRaiseDelay(LIMIT_RAISE_DELAY);
        d.module.setDustFloor(DUST_FLOOR_USD);

        SpendTokenParams[] memory tokens = spendTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            SpendTokenParams memory t = tokens[i];

            // `allowSpendToken` reads decimals from the token but never cross-checks the provider's
            // cached `tokenDecimals`, despite the shared error name. A mismatch would misprice every
            // settlement.
            PriceFeedConfig memory feed = d.provider.getConfig(t.token);
            require(feed.kind != PriceFeedKind.NONE, string.concat(t.label, " has no feed - see priceFeeds()"));
            require(
                feed.tokenDecimals == ERC20(t.token).decimals(),
                string.concat(t.label, " decimals disagree with provider config")
            );
            require(
                t.minPriceUsd >= feed.minPriceUsd && t.maxPriceUsd <= feed.maxPriceUsd,
                string.concat(t.label, " module band must be no wider than the provider band")
            );

            // Proved priceable before it is allowlisted. A token allowlisted while unpriceable is a
            // silent understatement of every holder's spending power, and reverts any `spend` that
            // touches it - which on the sweep path is a settlement stuck in arrears.
            (uint256 price, bool usable) = d.provider.priceUsd(t.token);
            require(usable, string.concat("provider cannot price ", t.label));
            logUsd(string.concat("  ", t.label, " price"), price);

            d.module.allowSpendToken(t.token, t.haircutBps, t.minPriceUsd, t.maxPriceUsd);
            console.log(string.concat("  allowlisted: ", t.label), t.token);
        }

        logUsd("  maxPerTx", MAX_PER_TX_USD);
        logUsd("  maxDaily", MAX_DAILY_LIMIT_USD);
        logUsd("  maxMonthly", MAX_MONTHLY_LIMIT_USD);

        // Every allowlisted token is read on the lens' single authorize call, which the backend runs
        // inside a 300ms budget. Growing this list grows that read, so VerifySpendModule.s.sol asserts
        // `availableToSpend` still answers.
        console.log("  allowlist size:", d.module.allowedTokens().length);
    }

    /**
     * @dev Mandatory. Until this runs an EOA can raise the org ceilings and allowlist tokens over live
     *      user funds. SKIP_HANDOVER exists only for a fork rehearsal where the deployer stays owner.
     *
     *      Grant before renounce on the provider, or the proxy becomes permanently unadministrable and
     *      un-upgradeable. Module last, because it gates redoing any of the rest.
     */
    function _maybeHandOver() private {
        if (vm.envOr("SKIP_HANDOVER", false) || d.finalOwner == d.deployer) {
            console.log("\nWARNING: handover skipped - the deployer still owns everything.");
            console.log("         Run HandOverOwnership.s.sol before this is used with real funds.");
            return;
        }

        console.log("\n[handover]");
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        bytes32 PRICE_ADMIN_ROLE = keccak256("PRICE_ADMIN_ROLE");
        bytes32 UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

        d.provider.grantRole(DEFAULT_ADMIN_ROLE, d.finalOwner);
        d.provider.grantRole(UPGRADER_ROLE, d.finalOwner);
        d.provider.grantRole(PRICE_ADMIN_ROLE, d.priceAdmin);
        require(d.provider.hasRole(DEFAULT_ADMIN_ROLE, d.finalOwner), "refusing to renounce into a bricked proxy");

        d.provider.renounceRole(PRICE_ADMIN_ROLE, d.deployer);
        d.provider.renounceRole(UPGRADER_ROLE, d.deployer);
        d.provider.renounceRole(DEFAULT_ADMIN_ROLE, d.deployer);
        console.log("  provider roles ->", d.finalOwner);

        if (d.authority.owner() == d.deployer) {
            d.authority.transferOwnership(d.finalOwner);
            console.log("  authority owner ->", d.finalOwner);
        }
        if (d.module.owner() == d.deployer) {
            d.module.transferOwnership(d.finalOwner);
            console.log("  module owner    ->", d.finalOwner);
        }
    }

    function _record() private {
        saveAddress("SolidPriceProviderImplementation", d.implementation);
        saveAddress("FuseRolesAuthority", address(d.authority));
        saveAddress("SolidCashModule", address(d.module));
        saveAddress("SolidCashLens", address(d.lens));
        saveAddress("SettlementTreasury", d.treasury);
        saveAddress("SolidPriceProvider", address(d.provider));
    }
}
