// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {Authority} from "@solmate/auth/Auth.sol";

import {ChainlinkQuoteAdapter} from "src/spend-module/v2/adapters/ChainlinkQuoteAdapter.sol";
import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {SolidLiquidator} from "src/spend-module/v2/SolidLiquidator.sol";
import {SolidPriceProviderV2} from "src/spend-module/v2/SolidPriceProviderV2.sol";
import {SolidSpendLens} from "src/spend-module/v2/SolidSpendLens.sol";
import {PriceFeedConfigV2} from "src/spend-module/v2/interfaces/ISolidPriceProviderV2.sol";

import {SpendModuleV2BaseConfig} from "./SpendModuleV2BaseConfig.sol";
import {ERC1967ProxyLite} from "./ERC1967ProxyLite.sol";

/**
 * @title DeploySpendModuleV2Base
 * @notice **Base step 2.** The whole dollar-denominated Base instance, EURC spendable.
 *
 * @dev **Debit only.** No collateral, no credit, no soEUR. That is not a staged rollout for its own
 *      sake: it keeps the first deployment on a new chain to exactly two new things, a second
 *      module instance and a real oracle adapter, so a failure has one of two causes rather than
 *      six. Credit needs soEUR, which does not exist anywhere yet.
 *
 *      **Differences from the Fuse deployment, all of them structural:**
 *
 *        - **A fresh price provider**, not an upgrade. Fuse upgrades a live proxy that the v1 cohort
 *          depends on, which is why that is its own step run by its own key. Base has no live
 *          consumer, so the provider is deployed and initialised here.
 *        - **No v1.** Both the module and the lens reject a zero `v1Module`, so a sentinel is used.
 *          See `baseV1Sentinel` for why that is a deployment problem rather than a code one.
 *        - **A fresh authority.** The Base card system gets its own rather than borrowing the LBTC
 *          vault's, because sharing one would mean a role granted for a vault reaches a card module.
 *          Override with `AUTHORITY` to reuse an existing one deliberately.
 *        - **No soUSD ceiling to anchor.** EURC does not appreciate, so its band is static.
 *
 *        forge script script/spend-module/v2/base/DeploySpendModuleV2Base.s.sol \
 *          --rpc-url base --broadcast --slow -vvv \
 *          --libraries src/spend-module/v2/libraries/SpendingLimitLibV2.sol:SpendingLimitLibV2:0x.. \
 *          --libraries src/spend-module/v2/libraries/SolidCreditMathLib.sol:SolidCreditMathLib:0x.. \
 *          --libraries src/spend-module/v2/libraries/SolidCashConfigLib.sol:SolidCashConfigLib:0x..
 *
 *      State is carried in a struct because the sequence otherwise exceeds the addressable stack.
 */
contract DeploySpendModuleV2Base is SpendModuleV2BaseConfig {
    struct BaseDeployment {
        address deployer;
        address finalOwner;
        address spender;
        address creditSpender;
        address guardian;
        address liquidationOperator;
        address treasury;
        address v1Sentinel;
        ChainlinkQuoteAdapter adapter;
        RolesAuthority authority;
        SolidPriceProviderV2 provider;
        SolidCashModuleV2Setters setters;
        SolidCashModuleV2 core;
        SolidLiquidator liquidator;
        SolidSpendLens lens;
        bool rolesConfigured;
    }

    BaseDeployment internal b;

    function run() external {
        requireBaseChain();
        _resolve();

        vm.startBroadcast();
        _deployAuthority();
        _deployProvider();
        _configureProviderForEurc();
        _deployHalves();
        _configureModule();
        _deployLiquidatorAndLens();
        _configureRoles();
        _handOver();
        vm.stopBroadcast();

        _record();
        _printOutstanding();
    }

    // ========================================= RESOLUTION =========================================

    function _resolve() private {
        b.deployer = msg.sender;
        b.finalOwner = owner();
        b.spender = spender();
        b.creditSpender = creditSpender();
        b.guardian = guardian();
        b.liquidationOperator = liquidationOperator();
        b.treasury = settlementTreasury();
        b.v1Sentinel = baseV1Sentinel();

        // Step 1's output. Refused rather than redeployed: a second adapter would be a second thing
        // the multisig has to vouch for, and the one from step 1 has already been configured.
        b.adapter = ChainlinkQuoteAdapter(requireAddress("ChainlinkQuoteAdapter", "DeployChainlinkAdapterBase.s.sol"));
        requireHasCode(address(b.adapter), "ChainlinkQuoteAdapter");

        // The same two key rules as Fuse, for the same reasons.
        require(b.guardian != b.spender && b.guardian != b.creditSpender, "GUARDIAN must be its own key");
        require(
            b.liquidationOperator != b.creditSpender && b.liquidationOperator != b.spender,
            "LIQUIDATION_OPERATOR must not be a spender key - see bookForcedSpend"
        );
        require(b.treasury != baseEurc(), "settlementTreasury must not be a spend token");
        require(b.treasury != b.deployer, "settlementTreasury must not be the deployer");

        console.log("\n=== Base step 2: SolidCashModuleV2 (USD unit, EURC spendable) ===");
        console.log("Deployer:             ", b.deployer);
        console.log("Final owner:          ", b.finalOwner);
        console.log("Spender:              ", b.spender);
        console.log("Credit spender:       ", b.creditSpender);
        console.log("Guardian:             ", b.guardian);
        console.log("Liquidation operator: ", b.liquidationOperator);
        console.log("Settlement treasury:  ", b.treasury, "<-- IMMUTABLE");
        console.log("Adapter:              ", address(b.adapter));
        logBaseInputs();

        // Proven before anything is deployed against it: step 1 may have deployed the adapter
        // without the multisig having executed `setQuote` yet, which would leave EURC unpriceable
        // and every allowlist check below failing after the gas is spent.
        (uint256 probe, bool usable,) = b.adapter.price(baseEurc());
        require(usable && probe != 0, "adapter cannot price EURC - has the OWNER run setQuote?");
        logUsd("  EURC via adapter    ", probe);
    }

    // ========================================= DEPLOY =========================================

    function _deployAuthority() private {
        console.log("\n[1/7] RolesAuthority");

        address existing = vm.envOr("AUTHORITY", address(0));
        if (existing != address(0)) {
            b.authority = RolesAuthority(existing);
            requireHasCode(existing, "authority");
            console.log("  reusing:            ", existing);
            return;
        }

        // Owned by the deployer for now so the role table can be written in this script, then handed
        // to the multisig in `_handOver`. On Fuse the authority is already the multisig's, which is
        // why that deployment can only print its role calls.
        b.authority = new RolesAuthority(b.deployer, Authority(address(0)));
        console.log("  deployed:           ", address(b.authority));
    }

    /**
     * @dev A fresh UUPS proxy, initialised to the deployer so this script can configure EURC, then
     *      handed to the multisig at the end.
     *
     *      `initialize` grants `DEFAULT_ADMIN_ROLE`, `PRICE_ADMIN_ROLE` and `UPGRADER_ROLE` to one
     *      address. The handover therefore has to grant all three to the multisig and renounce all
     *      three here, or the deployer keeps the ability to upgrade the contract that prices
     *      everyone's collateral.
     */
    function _deployProvider() private {
        console.log("\n[2/7] SolidPriceProviderV2");

        SolidPriceProviderV2 implementation = new SolidPriceProviderV2();
        console.log("  implementation:     ", address(implementation));

        // ERC1967 proxy via the implementation's own initializer, deployed with `upgradeToAndCall`
        // semantics through OZ's proxy. Kept explicit rather than using a helper so the initializer
        // argument is visible at the call site.
        bytes memory initData = abi.encodeCall(SolidPriceProviderV2.initialize, (b.deployer));
        address proxy = address(new ERC1967ProxyLite(address(implementation), initData));

        b.provider = SolidPriceProviderV2(proxy);
        console.log("  proxy:              ", proxy);

        require(b.provider.hasRole(b.provider.UPGRADER_ROLE(), b.deployer), "initializer did not grant roles");
    }

    function _configureProviderForEurc() private {
        console.log("\n[3/7] Provider: EURC");

        // The timelocked key vouches for an adapter; the day-to-day key may only point a token at
        // one already vouched for. Both are the deployer here and separate after handover.
        b.provider.setAdapterAllowed(address(b.adapter), true);

        PriceFeedConfigV2 memory feed = baseEurcFeedConfig(address(b.adapter));
        require(feed.tokenDecimals == ERC20(baseEurc()).decimals(), "EURC decimals disagree with the feed config");

        b.provider.setTokenConfig(baseEurc(), feed);

        (uint256 price, bool usable,) = b.provider.priceUsdDetailed(baseEurc());
        require(usable && price != 0, "provider cannot price EURC after configuration");
        logUsd("  EURC via provider   ", price);
    }

    function _deployHalves() private {
        console.log("\n[4/7] Module halves");

        b.setters = new SolidCashModuleV2Setters(b.deployer, address(b.authority), b.treasury, b.v1Sentinel);
        console.log("  setters:            ", address(b.setters));

        b.core = new SolidCashModuleV2(
            b.deployer, address(b.authority), b.treasury, b.v1Sentinel, address(b.provider)
        );
        console.log("  core:               ", address(b.core));

        b.core.setSettersImpl(address(b.setters));
        require(b.core.settersImpl() == address(b.setters), "setSettersImpl did not take");
    }

    function _configureModule() private {
        console.log("\n[5/7] Params, allowlist, tender");

        SolidCashModuleV2Setters(address(b.core)).setParams(baseParams());
        SolidCashModuleV2Setters(address(b.core)).setBorrowApyPerSecond(BORROW_APY_PER_SECOND);

        requireHasCode(baseEurc(), "EURC");
        SolidCashModuleV2Setters(address(b.core)).allowToken(baseEurc(), baseEurcConfig());

        // Two layers or one. Identical bands were a standing finding against v1, and the module's
        // independent band is the entire argument for tolerating an upgradeable provider.
        PriceFeedConfigV2 memory feed = b.provider.getConfig(baseEurc());
        require(
            EURC_MIN_PRICE_USD < feed.minPriceUsd && EURC_MAX_PRICE_USD > feed.maxPriceUsd,
            "module band must sit strictly outside the provider band"
        );

        (uint256 price, bool usable, bool inBand) = b.core.getPriceUsd(baseEurc());
        require(usable && inBand, "EURC not strictly priceable after allowlisting");
        logUsd("  EURC via module     ", price);

        // **EURC is not tender.** Tender decides how much DEBT an incoming payment retires, and no
        // debt can exist on a debit-only instance. Leaving it off means the day credit is enabled,
        // accepting EURC as repayment is a deliberate decision rather than an inherited default.
        console.log("  tender:              none (debit-only launch)");
        console.log("  collateral:          none (EURC is spend-only)");
    }

    function _deployLiquidatorAndLens() private {
        console.log("\n[6/7] Liquidator and lens");

        b.liquidator = new SolidLiquidator(b.finalOwner, address(b.authority), address(b.core), b.treasury);
        require(b.liquidator.settlementTreasury() == b.core.settlementTreasury(), "liquidator treasury mismatch");
        console.log("  liquidator:         ", address(b.liquidator));

        // Deployed even though nothing can be liquidated on a debit-only instance, because granting
        // `LIQUIDATOR_ROLE` later would be a role change on a live module rather than part of a
        // reviewed deployment.
        b.lens = new SolidSpendLens(b.v1Sentinel, address(b.core));
        console.log("  lens:               ", address(b.lens));
    }

    function _configureRoles() private {
        console.log("\n[7/7] Roles");

        if (b.authority.owner() != b.deployer) {
            console.log("  authority owned by", b.authority.owner(), "- grants are a multisig action");
            return;
        }

        address core = address(b.core);

        b.authority.setRoleCapability(SPENDER_ROLE, core, SolidCashModuleV2.spend.selector, true);
        b.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.spendCredit.selector, true);
        b.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.bookForcedSpend.selector, true);
        b.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.adjustBookedSpend.selector, true);
        b.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.reverseSpend.selector, true);

        b.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.pause.selector, true);
        b.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.unpause.selector, true);
        b.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setSafePaused.selector, true);
        b.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setTokenPaused.selector, true);
        b.authority.setRoleCapability(
            GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setLiquidationsPaused.selector, true
        );

        // The role goes to the CONTRACT, never an EOA. See `LIQUIDATOR_ROLE`.
        b.authority.setRoleCapability(LIQUIDATOR_ROLE, core, SolidCashModuleV2.liquidate.selector, true);
        b.authority.setUserRole(address(b.liquidator), LIQUIDATOR_ROLE, true);

        b.authority.setRoleCapability(
            LIQUIDATION_OPERATOR_ROLE, address(b.liquidator), SolidLiquidator.liquidate.selector, true
        );
        b.authority.setUserRole(b.liquidationOperator, LIQUIDATION_OPERATOR_ROLE, true);

        // `repayFromSafe` and `repayFromCollateral` are deliberately NOT granted, matching Fuse:
        // the backend may notify a drifting position, never act on a user's assets for them.

        b.authority.setUserRole(b.spender, SPENDER_ROLE, true);
        b.authority.setUserRole(b.creditSpender, CREDIT_SPENDER_ROLE, true);
        b.authority.setUserRole(b.guardian, GUARDIAN_ROLE, true);

        b.rolesConfigured = true;
        console.log("  granted");
    }

    /**
     * @dev Everything the deployer holds moves to the multisig here, and the provider is the part
     *      that is easy to half-finish: its three roles were all granted to the deployer by
     *      `initialize`, and leaving any one behind leaves an EOA able to upgrade the contract that
     *      prices every user's assets.
     */
    function _handOver() private {
        if (vm.envOr("SKIP_HANDOVER", false) || b.finalOwner == b.deployer) {
            console.log("\nWARNING: handover skipped - the deployer still owns everything.");
            return;
        }

        console.log("\n[handover]");

        b.core.transferOwnership(b.finalOwner);
        console.log("  core owner ->       ", b.finalOwner);

        if (b.authority.owner() == b.deployer) {
            b.authority.transferOwnership(b.finalOwner);
            console.log("  authority owner ->  ", b.finalOwner);
        }

        bytes32 admin = b.provider.DEFAULT_ADMIN_ROLE();
        bytes32 priceAdmin = b.provider.PRICE_ADMIN_ROLE();
        bytes32 upgrader = b.provider.UPGRADER_ROLE();

        b.provider.grantRole(admin, b.finalOwner);
        b.provider.grantRole(priceAdmin, b.finalOwner);
        b.provider.grantRole(upgrader, b.finalOwner);

        // Renounced in this order so the admin role, which can regrant the others, goes last.
        b.provider.renounceRole(upgrader, b.deployer);
        b.provider.renounceRole(priceAdmin, b.deployer);
        b.provider.renounceRole(admin, b.deployer);

        require(!b.provider.hasRole(upgrader, b.deployer), "deployer still holds UPGRADER_ROLE");
        require(!b.provider.hasRole(admin, b.deployer), "deployer still holds DEFAULT_ADMIN_ROLE");
        console.log("  provider roles ->   ", b.finalOwner);
    }

    function _record() private {
        console.log("\n[record]", deploymentPath());
        saveAddress("ChainlinkQuoteAdapter", address(b.adapter));
        saveAddress("SolidCashModuleV2Setters", address(b.setters));
        saveAddress("SolidCashModuleV2", address(b.core));
        saveAddress("SolidLiquidator", address(b.liquidator));
        saveAddress("SolidSpendLens", address(b.lens));
        saveAddress("SettlementTreasury", b.treasury);
    }

    function _printOutstanding() private view {
        console.log("\n=== outstanding ===");
        if (!b.rolesConfigured) {
            console.log("  Role grants           -> AUTHORITY owner");
        }
        console.log("  core.sealSetters()    -> OWNER multisig");
        console.log("  Fund SolidLiquidator  -> TREASURY (only once credit is enabled)");
        console.log("  Backend:");
        console.log("    - add EURC to TOKEN_SETTLEMENT_CURRENCY, or the FX waiver never fires");
        console.log("    - register this chain in each user's `deployments`");
        console.log("    - CASH_SPEND_LENS_ADDRESS for 8453 ->", address(b.lens));
    }
}
