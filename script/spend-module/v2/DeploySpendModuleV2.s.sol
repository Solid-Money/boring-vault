// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {SolidLiquidator} from "src/spend-module/v2/SolidLiquidator.sol";
import {SolidSpendLens} from "src/spend-module/v2/SolidSpendLens.sol";
import {SolidPriceProviderV2} from "src/spend-module/v2/SolidPriceProviderV2.sol";
import {ISolidPriceProviderV2, PriceFeedConfigV2} from "src/spend-module/v2/interfaces/ISolidPriceProviderV2.sol";
import {TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";

import {SpendModuleV2Verifier} from "./SpendModuleV2Verifier.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/**
 * @title DeploySpendModuleV2
 * @notice Step C of the v2 rollout: deploy both halves, configure them, hand ownership over.
 * @dev **This is not the whole deployment.** Three of the five steps are executed by keys this script
 *      does not hold, and it refuses to guess on their behalf:
 *
 *        A. `UpgradePriceProviderV2.s.sol`  (UPGRADER_ROLE)   — upgrade the live provider
 *        C. this script                     (any deployer)     — deploy and configure v2
 *        D. authority role grants           (OWNER multisig)   — calldata printed below
 *        E. `SealSettersV2.s.sol`           (OWNER multisig)   — close the upgrade hatch
 *        F. `VerifySpendModuleV2.s.sol`     (anyone)           — assert all of the above
 *
 *      A comes first because it touches the price provider that the LIVE v1 module depends on,
 *      and this script asserts both have happened rather than deploying against a provider that
 *      cannot answer. D is a multisig action because v1's authority was already handed over; when
 *      this script does not own it, it prints the exact calldata instead of failing.
 *
 *      Rehearse (no broadcast, nothing recorded):
 *        forge script script/spend-module/v2/DeploySpendModuleV2.s.sol --fork-url $FUSE_RPC_URL -vvv
 *
 *      Deploy, with libraries linked at known addresses (see the README on why to pre-deploy them):
 *        forge script script/spend-module/v2/DeploySpendModuleV2.s.sol \
 *          --rpc-url fuse --broadcast --slow -vvv \
 *          --libraries src/spend-module/v2/libraries/SpendingLimitLibV2.sol:SpendingLimitLibV2:0x.. \
 *          --libraries src/spend-module/v2/libraries/SolidCreditMathLib.sol:SolidCreditMathLib:0x.. \
 *          --libraries src/spend-module/v2/libraries/SolidCashConfigLib.sol:SolidCashConfigLib:0x..
 *
 *      State is carried in a struct rather than locals because the sequence otherwise exceeds the
 *      EVM's addressable stack depth.
 */
contract DeploySpendModuleV2 is SpendModuleV2Verifier {
    struct Deployment {
        address deployer;
        address finalOwner;
        address spender;
        address creditSpender;
        address guardian;
        address liquidationOperator;
        address treasury;
        address v1Module;
        SolidPriceProviderV2 provider;
        RolesAuthority authority;
        SolidCashModuleV2Setters setters;
        SolidCashModuleV2 core;
        SolidLiquidator liquidator;
        SolidSpendLens lens;
        uint64 sousdCeiling;
        uint64 anchor;
        bool rolesConfigured;
    }

    Deployment internal d;

    function run() external {
        require(block.chainid == FUSE_CHAIN_ID, "phase 3 targets Fuse (122) only");

        _resolveKeys();
        _requireProviderUpgraded();

        vm.startBroadcast();
        _deployHalves();
        _wireSetters();
        _configureParams();
        _allowTokens();
        // Before `_configureRoles`, which grants `LIQUIDATOR_ROLE` to this contract's address.
        _deployLiquidator();
        _deployLens();
        _configureRoles();
        _handOver();
        vm.stopBroadcast();

        _record();

        verify(
            VerifyContext({
                provider: d.provider,
                authority: d.authority,
                core: d.core,
                setters: address(d.setters),
                lens: d.lens,
                v1Module: d.v1Module,
                treasury: d.treasury,
                spender: d.spender,
                creditSpender: d.creditSpender,
                guardian: d.guardian,
                liquidator: address(d.liquidator),
                liquidationOperator: d.liquidationOperator,
                finalOwner: d.finalOwner
            }),
            d.rolesConfigured
        );

        _printOutstanding();
    }

    /**
     * @notice The whole six-step sequence against a fork, in one run. Dry run only.
     * @dev Steps A, B, D and E are all executed by the owner multisig in production, so no single
     *      key can rehearse the sequence by broadcasting — and each `--fork-url` invocation starts a
     *      fresh fork, so running the scripts one after another rehearses each against a chain where
     *      the previous step never happened. This impersonates the role holders instead, which is
     *      the only way to see step C run against a provider that has actually been upgraded.
     *
     *      There is no step B any more: Supra is deprecated on Fuse and the USDC.e / USDT entries
     *      stay as the bare pegs the v1 implementation wrote. Everything else is exactly what the
     *      individual scripts do.
     *
     *        forge script script/spend-module/v2/DeploySpendModuleV2.s.sol --sig "rehearse()" \
     *          --fork-url $FUSE_RPC_URL -vvv
     */
    function rehearse() external {
        require(!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast), "rehearse() is dry-run only");
        require(block.chainid == FUSE_CHAIN_ID, "phase 3 targets Fuse (122) only");

        _resolveKeys();

        address upgrader = vm.envOr("UPGRADER", d.finalOwner);
        require(d.provider.hasRole(d.provider.UPGRADER_ROLE(), upgrader), "UPGRADER does not hold the role");

        console.log("\n=== REHEARSAL (impersonated, nothing broadcast) ===");

        console.log("\n[step A] upgrade the provider, as", upgrader);
        vm.startPrank(upgrader);
        IUUPS(address(d.provider)).upgradeToAndCall(address(new SolidPriceProviderV2()), "");
        vm.stopPrank();

        // No step B. Supra is deprecated on Fuse, so the USDC.e and USDT entries stay as the bare
        // pegs the v1 implementation wrote — which is sound because neither is collateral. See
        // `stableTokens()` and `_stableConfig()`.

        _requireProviderUpgraded();

        console.log("\n[step C] deploy, as", d.deployer);
        vm.startPrank(d.deployer);
        _deployHalves();
        _wireSetters();
        _configureParams();
        _allowTokens();
        _deployLiquidator();
        _deployLens();
        vm.stopPrank();

        console.log("\n[step D] grant roles, as", d.authority.owner());
        vm.startPrank(d.authority.owner());
        _grantRoles();
        vm.stopPrank();

        console.log("\n[handover + step E] as", d.deployer, "then", d.finalOwner);
        vm.prank(d.deployer);
        d.core.transferOwnership(d.finalOwner);
        vm.prank(d.finalOwner);
        d.core.sealSetters();

        verify(
            VerifyContext({
                provider: d.provider,
                authority: d.authority,
                core: d.core,
                setters: address(d.setters),
                lens: d.lens,
                v1Module: d.v1Module,
                treasury: d.treasury,
                spender: d.spender,
                creditSpender: d.creditSpender,
                guardian: d.guardian,
                liquidator: address(d.liquidator),
                liquidationOperator: d.liquidationOperator,
                finalOwner: d.finalOwner
            }),
            true
        );

        console.log("\n=== REHEARSAL PASSED - the whole sequence works against live Fuse state ===");
    }

    /// @dev Resolved first so a missing key or a missing v1 record fails before any gas is spent.
    function _resolveKeys() private {
        d.deployer = msg.sender;
        d.finalOwner = owner();
        d.spender = spender();
        d.creditSpender = creditSpender();
        d.guardian = guardian();
        d.liquidationOperator = liquidationOperator();
        d.treasury = settlementTreasury();

        d.v1Module = requireV1Address("SolidCashModule");
        d.authority = RolesAuthority(requireV1Address("FuseRolesAuthority"));
        d.provider = SolidPriceProviderV2(requireV1Address("SolidPriceProvider"));

        requireHasCode(d.v1Module, "v1 module");
        requireHasCode(address(d.authority), "authority");
        requireHasCode(address(d.provider), "price provider proxy");

        // The treasury proves a transfer arrived by its own balance delta, so a treasury that IS one
        // of those token contracts makes that check meaningless. Checked against every allowlisted
        // asset, not only soUSD.
        SpendTokenParams[] memory tokens = spendTokens(1e6, uint64(block.timestamp));
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(
                d.treasury != tokens[i].token,
                string.concat("settlementTreasury must not be a spend token (", tokens[i].label, ")")
            );
        }
        require(d.treasury != d.deployer, "settlementTreasury must not be the deployer");

        // Separate keys are preferred but NOT required, and the distinction is deliberate.
        //
        // What must be permanent is the ROLE split, because this module is not upgradeable: once
        // `spend` and `spendCredit` are gated on one role, no transaction can ever separate them
        // again. Which addresses hold those roles is the opposite — a grant on the shared
        // `FuseRolesAuthority`, reversible in either direction by the owner multisig at any time.
        //
        // So one key may hold both, and today that is the honest configuration: the backend has a
        // single `CASH_SPENDER_PRIVATE_KEY` in one service, so a second address would sit in the
        // same env, in the same pod, behind the same compromise — separation on paper only. Keep
        // the roles, collapse the keys, and split them for real when the credit path gets its own
        // signer or KMS identity.
        if (d.creditSpender == d.spender) {
            console.log("  NOTE: SPENDER and CREDIT_SPENDER are the same key.");
            console.log("        The role split is deployed but not in force; one compromise reaches both paths.");
            console.log("        Separating later is a grant on the authority, not a redeploy.");
        }

        // The guardian is NOT negotiable. It is the response to a compromised spender key, so a
        // guardian that shares an address with one is a brake wired to the thing it stops.
        require(d.guardian != d.spender && d.guardian != d.creditSpender, "GUARDIAN must be its own key");

        // Neither is the liquidation operator, and for a sharper reason than the guardian's.
        //
        // `bookForcedSpend` can create debt with no collateral behind it, because a mandatory card
        // authorization has already happened off-chain. While liquidation was permissionless, that
        // composed into a complete theft: book unbacked debt, then liquidate the position you just
        // created and keep the collateral plus the 5% bonus. Routing liquidation through
        // `SolidLiquidator` means the proceeds can only reach the treasury — but the reason a
        // compromise now needs TWO keys is only true while these two ARE two keys.
        require(
            d.liquidationOperator != d.creditSpender && d.liquidationOperator != d.spender,
            "LIQUIDATION_OPERATOR must not be a spender key - see bookForcedSpend"
        );

        console.log("Deployer:            ", d.deployer);
        console.log("Final owner:         ", d.finalOwner);
        console.log("Spender (v1 + v2):   ", d.spender);
        console.log("Credit spender:      ", d.creditSpender);
        console.log("Guardian:            ", d.guardian);
        console.log("Liquidation operator:", d.liquidationOperator);
        console.log("Settlement treasury: ", d.treasury, "<-- IMMUTABLE");
        console.log("v1 module (stays live):", d.v1Module);
        console.log("Authority (shared):  ", address(d.authority));
        console.log("Price provider proxy:", address(d.provider));
    }

    /**
     * @dev Steps A and B, asserted rather than assumed.
     *
     *      The provider is upgraded underneath a LIVE v1 module serving real cardholders, so it is
     *      done as its own transaction by its own key and this script only checks the result. A
     *      `priceUsdDetailed` that answers is proof the new implementation is behind the proxy;
     *      nothing else in the v2 surface is reachable if it is not.
     */
    function _requireProviderUpgraded() private view {
        (bool ok, bytes memory ret) = address(d.provider).staticcall(
            abi.encodeWithSelector(ISolidPriceProviderV2.priceUsdDetailed.selector, SOUSD)
        );
        require(
            ok && ret.length == 96,
            "provider is not on V2 - run step A (UpgradePriceProviderV2.s.sol) first"
        );

        (uint256 price, bool usable,) = abi.decode(ret, (uint256, bool, uint64));
        require(usable && price != 0, "provider is on V2 but cannot price soUSD");
        logUsd("  live soUSD price", price);

        // A bare peg is the one price no band can filter and no staleness bound can reject. Both
        // entries stay on one at launch, deliberately: neither token is a module token, and USDC.e
        // appears only as soUSD's accountant base — the unit its NAV is already denominated in.
        // This reports them anyway, because the day either becomes collateral it needs a
        // `STABLE_ADAPTER` feed and a real oracle first.
        address[] memory tokens = stableTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            PriceFeedConfigV2 memory cfg = d.provider.getConfig(tokens[i]);
            if (cfg.source == address(0)) console.log("  bare peg (expected, spend-only token):", tokens[i]);
        }
    }

    /**
     * @dev Both halves take the SAME `treasury` and `v1Module`. Immutables are baked into each
     *      contract's own bytecode, so a `delegatecall` into the setters reads the setters' copies —
     *      which is why `setSettersImpl` compares them rather than trusting this.
     */
    function _deployHalves() private {
        console.log("\n[1/6] SolidCashModuleV2Setters");
        d.setters = new SolidCashModuleV2Setters(d.deployer, address(d.authority), d.treasury, d.v1Module);
        console.log("  deployed:", address(d.setters));

        console.log("\n[2/6] SolidCashModuleV2");
        d.core = new SolidCashModuleV2(
            d.deployer, address(d.authority), d.treasury, d.v1Module, address(d.provider)
        );
        console.log("  deployed:", address(d.core));
    }

    function _wireSetters() private {
        console.log("\n[3/6] setSettersImpl");
        d.core.setSettersImpl(address(d.setters));
        require(d.core.settersImpl() == address(d.setters), "setSettersImpl did not take");
        console.log("  wired, immutables agree");
    }

    /**
     * @dev Org ceilings and defaults land together: `registerSafe` checks a Safe's caps — chosen or
     *      defaulted — against the live ceilings, so a default above a ceiling makes every
     *      registration revert. `SolidCashConfigLib.validateParams` enforces the rest.
     */
    function _configureParams() private {
        console.log("\n[4/6] Params");
        SolidCashModuleV2Setters(address(d.core)).setParams(params());
        SolidCashModuleV2Setters(address(d.core)).setBorrowApyPerSecond(BORROW_APY_PER_SECOND);

        logUsd("  maxPerTx        ", MAX_PER_TX_USD);
        logUsd("  maxDaily        ", MAX_DAILY_LIMIT_USD);
        logUsd("  maxMonthly      ", MAX_MONTHLY_LIMIT_USD);
        logUsd("  maxDebtPerSafe  ", MAX_DEBT_PER_SAFE_USD);
        logUsd("  maxGlobalDebt   ", MAX_GLOBAL_DEBT_USD);
        logUsd("  maxForcedSpend  ", MAX_FORCED_SPEND_USD);
        console.log("  modeDelay       ", MODE_DELAY, "(0 = switching into Credit is immediate)");
        console.log("  limitRaiseDelay ", LIMIT_RAISE_DELAY, "(0 = raises apply immediately, matching v1)");
        console.log("  borrowApy/sec   ", BORROW_APY_PER_SECOND, "(continuously compounded; 4% effective/yr)");
    }

    /**
     * @dev The soUSD ceiling is computed from the LIVE price rather than written as a constant, and
     *      anchored at this block. A static ceiling on an appreciating asset is an outage with a
     *      computable date — above it, debit settlement, collateral locking, all three repay paths
     *      and liquidation refuse at once.
     */
    function _allowTokens() private {
        console.log("\n[5/6] Allowlist");

        // Read from the PROVIDER, not the module: soUSD is not allowlisted yet, and `_price` returns
        // (0, false, false) for a token with no config — so asking the module here would always
        // anchor the ceiling at zero.
        (uint256 sousdPrice, bool sousdUsable) = d.provider.priceUsd(SOUSD);
        require(sousdUsable && sousdPrice != 0, "cannot read soUSD price to anchor its ceiling");
        d.sousdCeiling = soUsdCeiling(sousdPrice);
        d.anchor = uint64(block.timestamp);

        logUsd("  soUSD live      ", sousdPrice);
        logUsd("  soUSD ceiling   ", d.sousdCeiling);

        SpendTokenParams[] memory tokens = spendTokens(d.sousdCeiling, d.anchor);
        for (uint256 i = 0; i < tokens.length; ++i) {
            SpendTokenParams memory t = tokens[i];
            requireHasCode(t.token, t.label);

            // A token allowlisted while unpriceable is a silent understatement of every holder's
            // spending power and reverts every spend that touches it — on the sweep path, that is a
            // settlement stuck in arrears.
            PriceFeedConfigV2 memory feed = d.provider.getConfig(t.token);
            require(
                feed.tokenDecimals == ERC20(t.token).decimals(),
                string.concat(t.label, ": provider decimals disagree with the token")
            );
            require(
                t.config.minPriceUsd >= feed.minPriceUsd && t.config.maxPriceUsd <= feed.maxPriceUsd,
                string.concat(t.label, ": module band must sit inside the provider band")
            );
            require(
                t.config.minPriceUsd != feed.minPriceUsd || t.config.maxPriceUsd != feed.maxPriceUsd,
                string.concat(t.label, ": module and provider bands are identical - one layer, not two")
            );

            SolidCashModuleV2Setters(address(d.core)).allowToken(t.token, t.config);

            (uint256 price, bool usable, bool inBand) = d.core.getPriceUsd(t.token);
            require(usable && inBand, string.concat(t.label, ": not strictly priceable after allowlisting"));
            logUsd(string.concat("  ", t.label, " price   "), price);
        }

        console.log("  allowlist size  ", d.core.allowedTokens().length);

        // Tender is strictly narrower than spendable, and deliberately so: `_sizeRepay` uses a
        // token's price to decide how much DEBT an incoming payment retires, which a bare
        // uncorroborated peg cannot be trusted for. See `repayTenderTokens`.
        (address[] memory tender, string[] memory tenderLabels) = repayTenderTokens();
        for (uint256 i = 0; i < tender.length; ++i) {
            SolidCashModuleV2Setters(address(d.core)).setRepayTender(tender[i], true);
            console.log(string.concat("  tender          ", tenderLabels[i]));
        }

        // Stated rather than assumed: everything allowlisted that is NOT tender should be visible
        // here, because "spendable but not acceptable as payment" is the surprising direction.
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (!d.core.repayTender(tokens[i].token)) {
                console.log(string.concat("  NOT tender      ", tokens[i].label, " (spend-only, by design)"));
            }
        }
    }

    /**
     * @dev The only address that will hold `LIQUIDATOR_ROLE` on the core.
     *
     *      It takes the same `settlementTreasury` the module does, and forwards everything it
     *      receives there in the same transaction — so a liquidation's two legs converge on one
     *      address and nothing is left anywhere an operator key could reach.
     */
    function _deployLiquidator() private {
        console.log("\n[6/7] SolidLiquidator");
        d.liquidator = new SolidLiquidator(d.finalOwner, address(d.authority), address(d.core), d.treasury);
        require(d.liquidator.settlementTreasury() == d.core.settlementTreasury(), "liquidator treasury mismatch");
        console.log("  deployed:", address(d.liquidator));
        console.log("  operator:", d.liquidationOperator);
        console.log("  NOTE: fund it with repay-token float before the first liquidation.");
    }

    function _deployLens() private {
        console.log("\n[7/7] SolidSpendLens");
        d.lens = new SolidSpendLens(d.v1Module, address(d.core));
        console.log("  deployed:", address(d.lens));
    }

    /**
     * @dev Step D, when this script can do it.
     *
     *      v1's authority was handed to the multisig at v1 deploy, so in production the deployer does
     *      not own it and these are multisig transactions. Rather than fail — which would strand a
     *      deployed, configured, unusable module — it prints the exact calls.
     *
     *      Note every capability targets the CORE's address, including the ones implemented in the
     *      setters half: callers always reach the setters through the core's fallback, so the core is
     *      the `target` the authority is asked about.
     */
    function _configureRoles() private {
        console.log("\n[roles]");
        if (d.authority.owner() != d.deployer) {
            console.log("  authority is owned by", d.authority.owner());
            console.log("  -> step D is a multisig action. Calls required, all targeting the CORE:");
            _printRoleCalls();
            return;
        }

        _grantRoles();
        console.log("  SPENDER_ROLE        -> spend");
        console.log("  CREDIT_SPENDER_ROLE -> spendCredit, bookForcedSpend, adjust, reverse");
        console.log("    (NOT repayFromSafe / repayFromCollateral - the Safe repays itself; see step D)");
        console.log("  GUARDIAN_ROLE       -> pause, unpause, setSafePaused, setTokenPaused, setLiquidationsPaused");
        console.log("  LIQUIDATOR_ROLE     -> liquidate, held ONLY by SolidLiquidator");
        console.log("  LIQUIDATION_OPERATOR-> SolidLiquidator.liquidate");
    }

    /// @dev Step D's writes, with no decision about who is allowed to make them.
    function _grantRoles() private {
        address core = address(d.core);
        d.authority.setRoleCapability(SPENDER_ROLE, core, SolidCashModuleV2.spend.selector, true);

        d.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.spendCredit.selector, true);
        d.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.bookForcedSpend.selector, true);
        d.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.adjustBookedSpend.selector, true);
        d.authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.reverseSpend.selector, true);

        // `repayFromSafe` and `repayFromCollateral` are DELIBERATELY NOT GRANTED.
        //
        // Both are gated by `_requireSafeOrCreditSpender`, whose first branch is `msg.sender ==
        // safe`. Withholding the role therefore leaves the user's own self-service repayment fully
        // working while removing the backend's ability to spend a user's balance or unwind their
        // collateral without them. The backend may watch a position and notify; it may not act.
        //
        // What this gives up, stated so it is a decision and not an oversight: a position drifting
        // unhealthy is no longer deleveraged at face value, so its only remaining resolution is
        // `liquidate`, which takes `liquidationBonusBps` (5%) out of the same collateral. Solid also
        // loses the tool that keeps a position solvent when no third-party liquidator appears — on
        // Fuse that is a real possibility, and Solid liquidating its own users at a bonus is worse
        // for them than deleveraging at par would have been.
        //
        // It stays a capability the contract supports, so re-enabling it is one `setRoleCapability`
        // from the owner multisig rather than a new module. That asymmetry is the reason to express
        // this as a withheld grant rather than as a code change.

        d.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.pause.selector, true);
        d.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.unpause.selector, true);
        d.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setSafePaused.selector, true);
        d.authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setTokenPaused.selector, true);
        d.authority.setRoleCapability(
            GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setLiquidationsPaused.selector, true
        );

        // Liquidation is no longer permissionless. `bookForcedSpend` can create debt with no
        // collateral behind it, and while anyone could liquidate, that composed into a complete
        // theft: a compromised CREDIT_SPENDER books unbacked debt against any registered Safe, then
        // liquidates the position it just manufactured and keeps the collateral plus the bonus.
        //
        // The role goes to the CONTRACT, never to an EOA, because the contract is what guarantees
        // the proceeds reach the treasury.
        d.authority.setRoleCapability(LIQUIDATOR_ROLE, core, SolidCashModuleV2.liquidate.selector, true);
        d.authority.setUserRole(address(d.liquidator), LIQUIDATOR_ROLE, true);

        // And the operator key drives that contract. Distinct from both spender keys, asserted in
        // `_resolveKeys`, which is what makes a manufactured liquidation need two compromises.
        d.authority.setRoleCapability(
            LIQUIDATION_OPERATOR_ROLE, address(d.liquidator), SolidLiquidator.liquidate.selector, true
        );
        d.authority.setUserRole(d.liquidationOperator, LIQUIDATION_OPERATOR_ROLE, true);

        // The debit spender already holds SPENDER_ROLE from v1 and must keep it — the v1 cohort is
        // still being served by the same key.
        if (!d.authority.doesUserHaveRole(d.spender, SPENDER_ROLE)) {
            d.authority.setUserRole(d.spender, SPENDER_ROLE, true);
        }
        if (!d.authority.doesUserHaveRole(d.guardian, GUARDIAN_ROLE)) {
            d.authority.setUserRole(d.guardian, GUARDIAN_ROLE, true);
        }
        d.authority.setUserRole(d.creditSpender, CREDIT_SPENDER_ROLE, true);

        d.rolesConfigured = true;
    }

    function _printRoleCalls() private view {
        address core = address(d.core);
        _logCap(SPENDER_ROLE, core, SolidCashModuleV2.spend.selector, "spend");
        _logCap(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.spendCredit.selector, "spendCredit");
        _logCap(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.bookForcedSpend.selector, "bookForcedSpend");
        _logCap(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.adjustBookedSpend.selector, "adjustBookedSpend");
        _logCap(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.reverseSpend.selector, "reverseSpend");
        _logCap(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.pause.selector, "pause");
        _logCap(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.unpause.selector, "unpause");
        _logCap(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setSafePaused.selector, "setSafePaused");
        _logCap(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setTokenPaused.selector, "setTokenPaused");
        _logCap(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setLiquidationsPaused.selector, "setLiquidationsPaused");
        _logCap(LIQUIDATOR_ROLE, core, SolidCashModuleV2.liquidate.selector, "liquidate");
        _logCap(
            LIQUIDATION_OPERATOR_ROLE,
            address(d.liquidator),
            SolidLiquidator.liquidate.selector,
            "SolidLiquidator.liquidate (target is the LIQUIDATOR, not the core)"
        );

        console.log("    setUserRole(creditSpender, CREDIT_SPENDER_ROLE, true)");
        console.logBytes(abi.encodeCall(RolesAuthority.setUserRole, (d.creditSpender, CREDIT_SPENDER_ROLE, true)));

        console.log("    setUserRole(SolidLiquidator, LIQUIDATOR_ROLE, true)  <-- the CONTRACT, never an EOA");
        console.logBytes(
            abi.encodeCall(RolesAuthority.setUserRole, (address(d.liquidator), LIQUIDATOR_ROLE, true))
        );

        console.log("    setUserRole(liquidationOperator, LIQUIDATION_OPERATOR_ROLE, true)");
        console.logBytes(
            abi.encodeCall(RolesAuthority.setUserRole, (d.liquidationOperator, LIQUIDATION_OPERATOR_ROLE, true))
        );
    }

    function _logCap(uint8 role, address target, bytes4 sig, string memory label) private pure {
        console.log(string.concat("    setRoleCapability(role ", vm.toString(role), ", core, ", label, ", true)"));
        console.logBytes(abi.encodeCall(RolesAuthority.setRoleCapability, (role, target, sig, true)));
    }

    /**
     * @dev Mandatory. Until this runs an EOA can rewrite every parameter and allowlist tokens over
     *      live user funds — and can replace the setters implementation outright.
     *
     *      Sealing is deliberately NOT done here: it is the owner's call, after the deployment has
     *      been verified and soaked, and after this transfer the owner is the only key that can.
     */
    function _handOver() private {
        if (vm.envOr("SKIP_HANDOVER", false) || d.finalOwner == d.deployer) {
            console.log("\nWARNING: handover skipped - the deployer still owns the module.");
            console.log("         It can rewrite every parameter and replace the setters half.");
            return;
        }

        console.log("\n[handover]");
        d.core.transferOwnership(d.finalOwner);
        console.log("  core owner ->", d.finalOwner);
    }

    function _record() private {
        console.log("\n[record]", deploymentPath());
        saveAddress("SolidCashModuleV2Setters", address(d.setters));
        saveAddress("SolidCashModuleV2", address(d.core));
        saveAddress("SolidLiquidator", address(d.liquidator));
        saveAddress("SolidSpendLens", address(d.lens));
        saveAddress("SettlementTreasury", d.treasury);

        // Libraries are linked, not deployed by this script. Recorded when the addresses were passed
        // in, which is the reproducible path — see the README.
        _recordLibrary("SPENDING_LIMIT_LIB_V2", "SpendingLimitLibV2");
        _recordLibrary("SOLID_CREDIT_MATH_LIB", "SolidCreditMathLib");
        _recordLibrary("SOLID_CASH_CONFIG_LIB", "SolidCashConfigLib");
    }

    function _recordLibrary(string memory envKey, string memory recordKey) private {
        address value = vm.envOr(envKey, address(0));
        if (value != address(0)) saveAddress(recordKey, value);
        else console.log(string.concat("  ", recordKey, ": auto-deployed, see the broadcast artifact"));
    }

    function _printOutstanding() private view {
        console.log("\n=== outstanding ===");
        if (!d.rolesConfigured) {
            console.log("  D. Authority role grants  -> OWNER multisig, calldata printed above");
        }
        console.log("  D2. Fund SolidLiquidator with repay-token float -> TREASURY");
        console.log("       Without it the first liquidation reverts; `sweep` returns it at any time.");
        console.log("  E. core.sealSetters()     -> OWNER multisig");
        console.log("       forge script script/spend-module/v2/SealSettersV2.s.sol --rpc-url fuse --broadcast");
        console.log("  F. Re-verify once D and E have landed");
        console.log("       forge script script/spend-module/v2/VerifySpendModuleV2.s.sol --rpc-url fuse");
    }
}
