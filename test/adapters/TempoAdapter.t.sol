// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {BoringSwapper} from "src/base/Periphery/BoringSwapper.sol";
import {ISwapperTypes} from "src/interfaces/ISwapperTypes.sol";
import {AdapterRegistry} from "src/base/Periphery/AdapterRegistry.sol";
import {TempoAdapter} from "src/base/Periphery/adapters/TempoAdapter.sol";
import {TempoLimitOrderAdapter} from "src/base/Periphery/adapters/TempoLimitOrderAdapter.sol";
import {TempoLimitOrderManager} from "src/base/Periphery/TempoLimitOrderManager.sol";
import {ITempoLimitOrderManager} from "src/interfaces/ITempoLimitOrderManager.sol";
import {ITempoStablecoinDEX, ITIP20} from "src/interfaces/ITempoStablecoinDEX.sol";
import {TempoDexMath} from "src/helper/TempoDexMath.sol";
import {PriceValidator} from "src/base/Periphery/adapters/price/PriceValidator.sol";
import {IPriceValidator} from "src/interfaces/IPriceValidator.sol";
import {IAdapter} from "src/interfaces/IAdapter.sol";
import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";
import {IRateProvider} from "src/interfaces/IRateProvider.sol";
import {FeeRegistry} from "src/base/Periphery/FeeRegistry.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {Test, console} from "@forge-std/Test.sol";

// ============================ Tempo predeploy surfaces (test-only) ============================

interface ITIP20Factory {
    function createToken(
        string memory name,
        string memory symbol,
        string memory currency,
        address quoteToken,
        address admin,
        bytes32 salt
    ) external returns (address);
}

interface ITIP20Test {
    function ISSUER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function mint(address to, uint256 amount) external;
    function transferPolicyId() external view returns (uint64);
    function changeTransferPolicyId(uint64 newPolicyId) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ITIP403Registry {
    function createPolicy(address admin, uint8 policyType) external returns (uint64);
    function modifyPolicyBlacklist(uint64 policyId, address account, bool restricted) external;
}

contract MockRateProvider is IRateProvider {
    function getRate() public pure override returns (uint256) {
        return 1e18; // all Tempo test stables are $1
    }
}

/// @notice Full-stack fork tests for the Tempo integration, executed against the REAL Tempo
///         precompiles (Rust) embedded in Foundry >= 1.7.0.
///
/// The tempo network family lives in the dedicated `[profile.tempo]` in foundry.toml
/// (requires Foundry >= 1.7.0), which pins `match_path` to the Tempo tests and skips `script/**`,
/// so the whole suite runs with just:
///   FOUNDRY_PROFILE=tempo forge test
///
/// Coverage maps to the design doc:
/// - user flows (§4.1): market exact-in/exact-out, limit submit/fill/harvest/cancel
/// - state transitions (§4.2): OPEN -> FILLED / CANCELLED / STRANDED->rescued
/// - invariants (§4.3): I1 selector surface, I2/I3 target+endpoint pinning, I5 hash determinism,
///   I6/I6a rounding + measured refunds, I7 fund destinations, I8 maker exclusivity, I9 monotone fills
/// - failure paths (§4.8) and threat-model behaviors (R5 fill/stale-cancel polarity)
contract TempoAdapterTest is Test {
    // Tempo predeploys
    ITempoStablecoinDEX internal constant DEX = ITempoStablecoinDEX(0xDEc0000000000000000000000000000000000000);
    ITIP20Factory internal constant FACTORY = ITIP20Factory(0x20Fc000000000000000000000000000000000000);
    ITIP403Registry internal constant REGISTRY_403 = ITIP403Registry(0x403c000000000000000000000000000000000000);
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;

    uint8 internal constant ADMIN_ROLE = 1;
    uint8 internal constant POLICY_BLACKLIST = 1;

    BoringVault public boringVault;
    BoringSwapper public swapper;
    AdapterRegistry public registry;
    PriceValidator public validator;
    RolesAuthority public rolesAuthority;
    FeeRegistry public feeRegistry;
    TempoAdapter public adapter; // market orders
    TempoLimitOrderAdapter public limitAdapter; // limit orders (separate rollout)
    TempoLimitOrderManager public manager;

    ERC20 internal BASE; // TIP-20 quoted in QUOTE
    ERC20 internal QUOTE; // TIP-20 quoted in pathUSD

    address internal lp = makeAddr("lp"); // third-party liquidity maker
    address internal taker = makeAddr("taker"); // third-party taker filling our maker orders
    address internal keeper = makeAddr("keeper"); // permissionless harvest caller

    function setUp() external {
        vm.createSelectFork("tempo");

        // ---- TIP-20 tokens: QUOTE quoted in pathUSD, BASE quoted in QUOTE (direct DEX pair) ----
        QUOTE = ERC20(FACTORY.createToken("Veda Quote USD", "vQUSD", "USD", PATH_USD, address(this), "vQUSD"));
        BASE = ERC20(FACTORY.createToken("Veda Base USD", "vBUSD", "USD", address(QUOTE), address(this), "vBUSD"));
        ITIP20Test(address(QUOTE)).grantRole(ITIP20Test(address(QUOTE)).ISSUER_ROLE(), address(this));
        ITIP20Test(address(BASE)).grantRole(ITIP20Test(address(BASE)).ISSUER_ROLE(), address(this));

        // ---- vault + swapper stack (mirrors BoringSwapper.t.sol) ----
        boringVault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));
        boringVault.setAuthority(rolesAuthority);

        registry = new AdapterRegistry();
        feeRegistry = new FeeRegistry(address(this), 1000);
        validator = new PriceValidator();
        swapper =
            new BoringSwapper(address(this), registry, feeRegistry, boringVault, IPriceValidator(address(validator)));

        swapper.setAuthority(rolesAuthority);
        rolesAuthority.setUserRole(address(this), ADMIN_ROLE, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.setRouteConfig.selector, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.setApprovedAdapter.selector, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.setTokenOracle.selector, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.setBaseAssetOracle.selector, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.swap.selector, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.submitOrder.selector, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.cancelOrder.selector, true);
        rolesAuthority.setRoleCapability(ADMIN_ROLE, address(swapper), BoringSwapper.releaseFee.selector, true);

        // ---- Tempo integration under test ----
        manager = new TempoLimitOrderManager(address(DEX), address(swapper), address(this), Authority(address(0)));
        adapter = new TempoAdapter(address(DEX));
        limitAdapter = new TempoLimitOrderAdapter(address(DEX), address(manager));
        registry.put(address(adapter), "TEMPO");
        registry.put(address(limitAdapter), "TEMPO_LIMIT");
        swapper.setApprovedAdapter(address(adapter), true);
        swapper.setApprovedAdapter(address(limitAdapter), true);

        // routes both directions, no rate limit
        swapper.setRouteConfig(BASE, QUOTE, 50, 0, 0);
        swapper.setRouteConfig(QUOTE, BASE, 50, 0, 0);

        // oracles: both tokens $1
        MockRateProvider one = new MockRateProvider();
        address usdQuoteAsset = address(QUOTE);
        swapper.setTokenOracle(BASE, usdQuoteAsset, _makeOracleConfig(address(one)));
        swapper.setTokenOracle(QUOTE, usdQuoteAsset, _makeOracleConfig(address(one)));
        swapper.setBaseAssetOracle(BASE, usdQuoteAsset, _toArray(address(one)));
        swapper.setBaseAssetOracle(QUOTE, usdQuoteAsset, _toArray(address(one)));

        // vault approves swapper to pull
        vm.startPrank(address(boringVault));
        BASE.approve(address(swapper), type(uint256).max);
        QUOTE.approve(address(swapper), type(uint256).max);
        vm.stopPrank();

        // balances
        ITIP20Test(address(BASE)).mint(address(boringVault), 10_000e6);
        ITIP20Test(address(QUOTE)).mint(address(boringVault), 10_000e6);
        ITIP20Test(address(BASE)).mint(lp, 10_000e6);
        ITIP20Test(address(QUOTE)).mint(lp, 10_000e6);
        ITIP20Test(address(BASE)).mint(taker, 10_000e6);
        ITIP20Test(address(QUOTE)).mint(taker, 10_000e6);

        // third parties approve the DEX directly
        vm.startPrank(lp);
        BASE.approve(address(DEX), type(uint256).max);
        QUOTE.approve(address(DEX), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(taker);
        BASE.approve(address(DEX), type(uint256).max);
        QUOTE.approve(address(DEX), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================ Market orders ============================================

    /// user flow §4.1 market exact-in: vault sells BASE into a resting bid, output lands in vault
    function testSwap_ExactIn() external {
        vm.prank(lp);
        DEX.place(address(BASE), 1_000e6, true, 0); // lp bids for base at peg

        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        swapper.swap(
            _marketConfig(
                BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(BASE), address(QUOTE), 500e6, 495e6))
            )
        );

        // tick 0 => 1:1, no rounding
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 500e6, "vault base spent");
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 500e6, "vault received quote");
        // I4: nothing left behind on the swapper, in wallet or internal DEX balance
        assertEq(BASE.balanceOf(address(swapper)), 0, "no wallet dust");
        assertEq(QUOTE.balanceOf(address(swapper)), 0, "no wallet dust");
        assertEq(DEX.balanceOf(address(swapper), address(BASE)), 0, "no internal balance");
        assertEq(DEX.balanceOf(address(swapper), address(QUOTE)), 0, "no internal balance");
        assertEq(BASE.allowance(address(swapper), address(DEX)), 0, "allowance reset");
    }

    /// user flow §4.1 market exact-out: only the computed input is consumed; the rest of
    /// maxAmountIn returns to the vault as dust. maxAmountIn must sit within the route's
    /// slippage bound because the validator prices the WORST-CASE pull (§3.1).
    function testSwap_ExactOut_UnspentInputReturnsToVault() external {
        vm.prank(lp);
        DEX.place(address(BASE), 1_000e6, false, 0); // lp asks base at peg

        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        // buy exactly 200e6 base, authorize up to 1bp of input headroom (within 10bps slippage)
        swapper.swap(
            _marketConfig(
                QUOTE, BASE, abi.encodeCall(DEX.swapExactAmountOut, (address(QUOTE), address(BASE), 200e6, 200_020_000))
            )
        );

        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore + 200e6, "vault received exact output");
        // tick 0: input needed is exactly 200e6; the 20_000 headroom pulled must come back as dust
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore - 200e6, "only computed input spent");
        assertEq(QUOTE.balanceOf(address(swapper)), 0, "dust returned");
        // I4: exact-out leaves no internal DEX balance on the swapper either
        assertEq(DEX.balanceOf(address(swapper), address(QUOTE)), 0, "no internal balance");
        assertEq(DEX.balanceOf(address(swapper), address(BASE)), 0, "no internal balance");
    }

    /// §3.1 conservative direction: the price validator sees maxAmountIn as the input amount, so
    /// an over-generous maxAmountIn is rejected even though the DEX would pull less
    function testSwap_ExactOut_ExcessiveMaxInputRejected() external {
        vm.prank(lp);
        DEX.place(address(BASE), 1_000e6, false, 0);

        vm.expectRevert(PriceValidator.PriceValidator__ExceedsMaxSlippage.selector);
        swapper.swap(
            _marketConfig(
                QUOTE, BASE, abi.encodeCall(DEX.swapExactAmountOut, (address(QUOTE), address(BASE), 200e6, 210e6))
            )
        );
    }

    /// failure path §4.8: DEX revert (output below min) surfaces as SwapFailed, no funds move
    function testSwap_RevertOutputBelowMin_NoFundsMove() external {
        vm.prank(lp);
        DEX.place(address(BASE), 1_000e6, true, 0);

        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));

        vm.expectRevert(BoringSwapper.BoringSwapper__SwapFailed.selector);
        swapper.swap(
            _marketConfig(
                BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(BASE), address(QUOTE), 500e6, 501e6))
            )
        );

        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore, "no funds moved on failed swap");
    }

    /// failure path §4.8: no liquidity at all
    function testSwap_RevertInsufficientLiquidity() external {
        vm.expectRevert(BoringSwapper.BoringSwapper__SwapFailed.selector);
        swapper.swap(
            _marketConfig(BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(BASE), address(QUOTE), 500e6, 1)))
        );
    }

    /// I3: calldata token endpoints must match the approved route
    function testSwap_RevertTokenMismatch() external {
        // swapData sells QUOTE but the route says BASE -> QUOTE
        vm.expectRevert(IAdapter.Adapter__TokenInMismatch.selector);
        swapper.swap(
            _marketConfig(BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(QUOTE), address(BASE), 500e6, 1)))
        );

        vm.expectRevert(IAdapter.Adapter__TokenOutMismatch.selector);
        swapper.swap(
            _marketConfig(BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(BASE), address(BASE), 500e6, 1)))
        );
    }

    /// I1: the adapter mirrors ONLY the two swap selectors — maker/balance DEX calls cannot be
    /// smuggled through the market-swap flow
    function testSwap_AdapterExposesNoMakerSelectors() external {
        bytes[] memory forbidden = new bytes[](5);
        forbidden[0] = abi.encodeCall(DEX.place, (address(BASE), 200e6, false, 0));
        forbidden[1] = abi.encodeCall(DEX.placeFlip, (address(BASE), 200e6, false, 0, -10));
        forbidden[2] = abi.encodeCall(DEX.withdraw, (address(BASE), 1));
        forbidden[3] = abi.encodeCall(DEX.cancel, (uint128(1)));
        forbidden[4] = abi.encodeCall(DEX.createPair, (address(BASE)));

        for (uint256 i; i < forbidden.length; i++) {
            // adapter has no matching function => pre-flight staticcall reverts
            vm.expectRevert();
            swapper.swap(_marketConfig(BASE, QUOTE, forbidden[i]));
        }
    }

    /// I1/I2: mirrored selectors match the DEX ABI exactly and the adapter pins the DEX target
    function testAdapter_MarketSelectorAndTarget() external {
        assertEq(
            TempoAdapter.swapExactAmountIn.selector, ITempoStablecoinDEX.swapExactAmountIn.selector, "selector mirror"
        );
        assertEq(
            TempoAdapter.swapExactAmountOut.selector, ITempoStablecoinDEX.swapExactAmountOut.selector, "selector mirror"
        );

        // simulate the swapper's appended-calldata staticcall
        ISwapperTypes.SwapConfig memory config = _marketConfig(
            BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(BASE), address(QUOTE), 500e6, 1))
        );
        bytes memory appended = abi.encodePacked(config.swapData, abi.encode(config), uint256(config.swapData.length));
        (bool ok, bytes memory ret) = address(adapter).staticcall(appended);
        assertTrue(ok, "adapter staticcall");
        (address target, uint256 amount) = abi.decode(ret, (address, uint256));
        assertEq(target, address(DEX), "I2: market target is the DEX");
        assertEq(amount, 500e6, "pull amount = amountIn");
    }

    /// rollout separation: each adapter serves exactly one flow, so limit orders can ship (or be
    /// paused) independently of market swaps via per-adapter approvals
    function testAdapterSplit_FlowsAreMutuallyExclusive() external {
        // market adapter rejects the limit-order flow outright
        (ISwapperTypes.SwapConfig memory limitConfig,) = _limitConfig(false, 10, 200e6, "s1");
        limitConfig.adapter = address(adapter);
        vm.expectRevert(IAdapter.Adapter__LimitOrdersNotSupported.selector);
        swapper.submitOrder(limitConfig);

        // limit adapter mirrors no market selectors, so market swapData dies at pre-flight
        ISwapperTypes.SwapConfig memory marketConfig = _marketConfig(
            BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(BASE), address(QUOTE), 500e6, 1))
        );
        marketConfig.adapter = address(limitAdapter);
        vm.expectRevert();
        swapper.swap(marketConfig);
    }

    // ======================================= verifyLimitOrder (unit) =======================================

    /// OrderInfo shape for an ask: escrow base exactly, conservative round-down output
    function testVerifyLimitOrder_Ask_OrderInfo() external {
        // amount 100_000_001 at tick 10 (price 1.0001): floor output = 100_010_001
        (ISwapperTypes.SwapConfig memory config, bytes32 expectedKey) = _limitConfig(false, 10, 100_000_001, "salt-1");

        IAdapter.OrderInfo memory info = limitAdapter.verifyLimitOrder(config, address(swapper));

        assertEq(info.approvalTarget, address(manager), "I2: approvalTarget = manager");
        assertEq(info.cancelTarget, address(manager), "I2: cancelTarget = manager");
        assertEq(info.hook, address(manager), "I2: hook = manager");
        assertEq(info.inputToken, address(BASE), "ask escrows base");
        assertEq(info.outputToken, address(QUOTE));
        assertEq(info.inputAmount, 100_000_001, "ask escrow is exact base");
        assertEq(info.outputAmount, 100_010_001, "floor(amount * 1.0001)");
        assertEq(info.protocolHash, expectedKey, "I5: hash = keccak(chainid, manager, swapData)");
        assertEq(abi.decode(info.context, (bytes32)), expectedKey, "context carries the key");
        assertEq(
            info.hookData,
            abi.encodeCall(
                ITempoLimitOrderManager.placeOrder,
                (expectedKey, address(BASE), false, int16(10), uint128(100_000_001), address(boringVault))
            ),
            "hookData places via manager"
        );
    }

    /// OrderInfo shape for a bid: escrow = ceil(amount * price) in quote — I6 rounding replication
    function testVerifyLimitOrder_Bid_EscrowRoundsUp() external {
        // 100_000_001 * 100_010 / 100_000 = 100_010_001.0001 -> ceil = 100_010_002
        (ISwapperTypes.SwapConfig memory config,) = _limitConfigRoute(true, 10, 100_000_001, "salt-1", QUOTE, BASE);

        IAdapter.OrderInfo memory info = limitAdapter.verifyLimitOrder(config, address(swapper));

        assertEq(info.inputToken, address(QUOTE), "bid escrows quote");
        assertEq(info.outputToken, address(BASE));
        assertEq(info.inputAmount, 100_010_002, "ceil(amount * 1.0001)");
        assertEq(info.outputAmount, 100_000_001, "bid output is base amount");
    }

    function testVerifyLimitOrder_Reverts() external {
        // unaligned tick
        (ISwapperTypes.SwapConfig memory config,) = _limitConfig(false, 15, 200e6, "s");
        vm.expectRevert(TempoDexMath.TempoDexMath__TickNotAligned.selector);
        limitAdapter.verifyLimitOrder(config, address(swapper));

        // out-of-bounds tick
        (config,) = _limitConfig(false, 2010, 200e6, "s");
        vm.expectRevert(TempoDexMath.TempoDexMath__TickOutOfBounds.selector);
        limitAdapter.verifyLimitOrder(config, address(swapper));

        // below the DEX maker minimum ($100)
        (config,) = _limitConfig(false, 10, 99_999_999, "s");
        vm.expectRevert(TempoLimitOrderAdapter.TempoLimitOrderAdapter__BelowMinimumOrderSize.selector);
        limitAdapter.verifyLimitOrder(config, address(swapper));

        // I3: ask must route base -> quote; a bid-shaped route is a mismatch
        (config,) = _limitConfigRoute(false, 10, 200e6, "s", QUOTE, BASE);
        vm.expectRevert(IAdapter.Adapter__TokenInMismatch.selector);
        limitAdapter.verifyLimitOrder(config, address(swapper));
    }

    /// I5: hash is a pure function of swapData — deterministic across calls, unique per salt
    function testVerifyLimitOrder_HashDeterminism() external {
        (ISwapperTypes.SwapConfig memory config,) = _limitConfig(false, 10, 200e6, "salt-a");
        bytes32 h1 = limitAdapter.verifyLimitOrder(config, address(swapper)).protocolHash;
        bytes32 h2 = limitAdapter.verifyLimitOrder(config, address(swapper)).protocolHash;
        assertEq(h1, h2, "deterministic");

        (ISwapperTypes.SwapConfig memory config2,) = _limitConfig(false, 10, 200e6, "salt-b");
        assertTrue(limitAdapter.verifyLimitOrder(config2, address(swapper)).protocolHash != h1, "salt varies hash");
    }

    // ======================================== Limit order lifecycle ========================================

    /// user flow §4.1 submit: escrow moves vault -> swapper -> manager -> DEX atomically
    function testSubmitLimitOrder_Ask() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 10, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);

        // manager record
        ITempoLimitOrderManager.OrderRecord memory rec = manager.getOrderRecord(address(swapper), key);
        assertGt(rec.dexOrderId, 0, "order placed");
        assertEq(rec.receiver, address(boringVault));
        assertEq(rec.inputAmount, 200e6);
        assertFalse(rec.closed);

        // live DEX order, maker-of-record is the manager
        ITempoStablecoinDEX.Order memory dexOrder = DEX.getOrder(rec.dexOrderId);
        assertEq(dexOrder.maker, address(manager), "manager is maker");
        assertEq(dexOrder.remaining, 200e6);
        assertEq(dexOrder.tick, 10);
        assertFalse(dexOrder.isBid);

        // funds: vault -> DEX escrow; nothing stranded on swapper or manager wallets
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 200e6);
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(BASE.balanceOf(address(swapper)), 0, "swapper wallet clean");

        // swapper-side accounting
        assertEq(swapper.pendingOrderPrincipal(BASE), 200e6);
        assertEq(address(swapper.getOrderRecord(orderId).tokenIn), address(BASE));

        // I9: nothing filled yet
        assertEq(limitAdapter.filledAmount(config, address(swapper), abi.encode(key)), 0);
    }

    /// state transition OPEN -> CANCELLED unfilled: full principal returns to the vault
    function testCancelLimitOrder_Unfilled_FullRefund() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 10, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);
        swapper.cancelOrder(orderId, config, "");

        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore, "full principal back");
        ITempoLimitOrderManager.OrderRecord memory rec = manager.getOrderRecord(address(swapper), key);
        assertTrue(rec.closed, "record closed");
        uint128 dexOrderId = rec.dexOrderId;
        vm.expectRevert(ITempoStablecoinDEX.OrderDoesNotExist.selector);
        DEX.getOrder(dexOrderId);
    }

    /// I6 round-trip: bid escrow uses ceil; cancelling refunds EXACTLY the escrow (the precompile's
    /// test_cancellation_refund_equals_escrow_for_bid_orders invariant, through our whole stack)
    function testCancelLimitOrder_Bid_EscrowRefundRoundTrip() external {
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config,) = _limitConfigRoute(true, 10, 100_000_001, "s1", QUOTE, BASE);
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore - 100_010_002, "ceil escrow pulled");

        swapper.cancelOrder(orderId, config, "");
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore, "escrow round-trips exactly");
    }

    /// user flow §4.1 fills + harvest (ask): partial fill accrues to manager's internal balance;
    /// permissionless harvest delivers proceeds to the vault only
    function testLimitOrder_Ask_PartialFill_HarvestAndCancel() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 0, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);

        // taker buys 60e6 base from our ask (tick 0 => 1:1)
        vm.prank(taker);
        DEX.swapExactAmountIn(address(QUOTE), address(BASE), 60e6, 59e6);

        // I9: filledAmount tracks the DEX exactly and is monotone
        assertEq(limitAdapter.filledAmount(config, address(swapper), abi.encode(key)), 60e6, "filled 60");

        // permissionless harvest (I7: proceeds can only go to the vault)
        vm.prank(keeper);
        uint128 proceeds = manager.harvest(address(swapper), key);
        assertEq(proceeds, 60e6);
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 60e6, "proceeds to vault");
        assertEq(QUOTE.balanceOf(keeper), 0, "keeper gets nothing");

        // second harvest with no new fills pays nothing
        vm.prank(keeper);
        assertEq(manager.harvest(address(swapper), key), 0, "idempotent");

        // cancel: refund = inputAmount - filledAmount, exactly
        swapper.cancelOrder(orderId, config, "");
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 60e6, "unfilled principal back");
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 60e6, "proceeds kept");
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");
    }

    /// same lifecycle on the bid side, where BOTH escrow and refund round (I6) — cancel also
    /// harvests outstanding proceeds in the same call
    function testLimitOrder_Bid_PartialFill_CancelHarvestsAndRefundsExactly() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfigRoute(true, 10, 200e6, "s1", QUOTE, BASE);
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);
        uint256 escrow = 200e6 * 100_010 / 100_000; // 200_020_000, exact at this amount

        // taker sells 60e6 base into our bid
        vm.prank(taker);
        DEX.swapExactAmountIn(address(BASE), address(QUOTE), 60e6, 1);

        uint256 filled = limitAdapter.filledAmount(config, address(swapper), abi.encode(key));
        assertEq(filled, 60e6 * 100_010 / 100_000, "filled input in quote units");

        // cancel without harvesting first: cancel must harvest + refund in one flow
        swapper.cancelOrder(orderId, config, "");

        // proceeds: bid maker receives filled base 1:1
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore + 60e6, "base proceeds harvested");
        // refund: escrow - filled, exactly — no wei lost anywhere (I6/I6a)
        assertEq(
            QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore - escrow + (escrow - filled), "exact quote refund"
        );
        assertEq(DEX.balanceOf(address(manager), address(QUOTE)), 0, "manager internal clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");
    }

    /// state transition OPEN -> FILLED: filledAmount == inputAmount blocks cancel; harvest
    /// delivers all proceeds
    function testLimitOrder_FullFill_BlocksCancelAndHarvests() external {
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 0, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);

        vm.prank(taker);
        DEX.swapExactAmountIn(address(QUOTE), address(BASE), 200e6, 199e6); // consumes the whole ask

        // order deleted on the DEX -> reported fully filled (R5 safe polarity)
        assertEq(limitAdapter.filledAmount(config, address(swapper), abi.encode(key)), 200e6);

        vm.expectRevert(BoringSwapper.BoringSwapper__OrderAlreadyFilled.selector);
        swapper.cancelOrder(orderId, config, "");

        vm.prank(keeper);
        manager.harvest(address(swapper), key);
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 200e6, "all proceeds to vault");

        // swapper-side settlement of a filled order
        swapper.releaseFee(orderId);
        assertEq(swapper.pendingOrderPrincipal(BASE), 0);
    }

    /// duplicate-hash protection lives in the swapper and keys off our deterministic hash
    function testSubmitLimitOrder_DuplicateHashRejected() external {
        (ISwapperTypes.SwapConfig memory config,) = _limitConfig(false, 10, 200e6, "s1");
        swapper.submitOrder(config);

        vm.expectRevert(BoringSwapper.BoringSwapper__DuplicateOrder.selector);
        swapper.submitOrder(config);

        // new salt => new hash => accepted
        (ISwapperTypes.SwapConfig memory config2,) = _limitConfig(false, 10, 200e6, "s2");
        swapper.submitOrder(config2);
    }

    /// failure path §4.8: submission-time fat-finger bound — a 20bp-off tick violates 10bp slippage
    function testSubmitLimitOrder_PriceValidatorFatFinger() external {
        (ISwapperTypes.SwapConfig memory config,) = _limitConfig(false, -200, 200e6, "s1");
        vm.expectRevert(); // PriceValidator slippage revert
        swapper.submitOrder(config);
    }

    // =========================================== Manager (unit) ===========================================

    function testManager_PlaceOrder_Guards() external {
        // placeOrder is pinned to the swapper — nobody else can place, regardless of funds
        ITIP20Test(address(BASE)).mint(address(this), 500e6);
        BASE.approve(address(manager), type(uint256).max);
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__NotSwapper.selector);
        manager.placeOrder("k", address(BASE), false, 10, 200e6, address(boringVault));

        // remaining guards, exercised as the pinned swapper
        ITIP20Test(address(BASE)).mint(address(swapper), 500e6);
        vm.startPrank(address(swapper));
        BASE.approve(address(manager), type(uint256).max);

        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__InvalidReceiver.selector);
        manager.placeOrder("k", address(BASE), false, 10, 200e6, address(0));

        manager.placeOrder("k", address(BASE), false, 10, 200e6, address(boringVault));
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__KeyAlreadyUsed.selector);
        manager.placeOrder("k", address(BASE), false, 10, 200e6, address(boringVault));
        vm.stopPrank();
    }

    /// I8: records are owner-scoped — another caller cannot touch our key
    function testManager_CancelOrder_OwnerScoped() external {
        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 10, 200e6, "s1");
        swapper.submitOrder(config);

        // rando's key-space is empty, so this is OrderNotFound — never someone else's order
        vm.prank(makeAddr("rando"));
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderNotFound.selector);
        manager.cancelOrder(key);

        // even the auth'd owner of the manager can't cancel the swapper's order
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderNotFound.selector);
        manager.cancelOrder(key);
    }

    function testManager_CancelOrder_ClosedIsTerminal() external {
        ITIP20Test(address(BASE)).mint(address(swapper), 500e6);
        vm.startPrank(address(swapper));
        BASE.approve(address(manager), type(uint256).max);
        manager.placeOrder("k", address(BASE), false, 10, 200e6, address(boringVault));

        manager.cancelOrder("k");
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderClosed.selector);
        manager.cancelOrder("k");
        vm.stopPrank();
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderClosed.selector);
        manager.harvest(address(swapper), "k");
    }

    /// walletBuffer accounting (§3.2): placing an ask while the manager holds unharvested internal
    /// BASE (from a filled bid) lets the DEX consume that internal credit first; the displaced
    /// wallet escrow must be re-attributed so BOTH orders still pay out exactly
    function testManager_WalletBuffer_InternalBalanceConsumedAtPlace() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));

        // order1: bid 150e6 base at peg (escrow 150e6 quote)
        (ISwapperTypes.SwapConfig memory bidConfig, bytes32 bidKey) =
            _limitConfigRoute(true, 0, 150e6, "bid", QUOTE, BASE);
        swapper.submitOrder(bidConfig);

        // fully fill it: manager now holds 150e6 BASE in INTERNAL DEX balance (unharvested)
        vm.prank(taker);
        DEX.swapExactAmountIn(address(BASE), address(QUOTE), 150e6, 1);
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 150e6, "unharvested internal proceeds");

        // order2: ask 120e6 base (escrow BASE) — DEX consumes internal balance first
        (ISwapperTypes.SwapConfig memory askConfig,) = _limitConfig(false, 0, 120e6, "ask");
        uint256 askOrderId = swapper.orders();
        swapper.submitOrder(askConfig);

        assertEq(manager.walletBuffer(address(BASE)), 120e6, "displaced escrow tracked");
        assertEq(BASE.balanceOf(address(manager)), 120e6, "escrow left in wallet");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 30e6, "internal reduced");

        // harvest order1: full 150e6 proceeds reach the vault (120 from buffer + 30 withdrawn)
        vm.prank(keeper);
        manager.harvest(address(swapper), bidKey);
        // vault base: -120e6 ask escrow, +150e6 bid proceeds
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 120e6 + 150e6, "order1 proceeds intact");
        assertEq(manager.walletBuffer(address(BASE)), 0, "buffer drained");
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");

        // cancel order2: its full escrow is still recoverable despite the internal-balance shuffle
        swapper.cancelOrder(askOrderId, askConfig, "");
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore + 150e6, "order2 escrow intact");
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");
    }

    // ============================================ Stale-cancel ============================================

    /// R5/STRANDED path end-to-end: TIP-403 blacklists the manager, a third party stale-cancels
    /// our order, the swapper correctly refuses to double-refund, and rescueStale recovers the
    /// principal to the vault once policy access is restored
    function testStaleCancel_RescueFlow() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 10, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);
        uint128 dexOrderId = manager.getOrderRecord(address(swapper), key).dexOrderId;

        // rescue is blocked while the order is live
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderStillActive.selector);
        manager.rescueStale(address(swapper), key, 200e6);

        // token admin swaps in a blacklist policy that blocks the manager
        uint64 originalPolicy = ITIP20Test(address(BASE)).transferPolicyId();
        uint64 blockPolicy = REGISTRY_403.createPolicy(address(this), POLICY_BLACKLIST);
        REGISTRY_403.modifyPolicyBlacklist(blockPolicy, address(manager), true);
        ITIP20Test(address(BASE)).changeTransferPolicyId(blockPolicy);

        // anyone can now clear our stale liquidity; refund lands in manager's INTERNAL balance
        vm.prank(makeAddr("rando"));
        DEX.cancelStaleOrder(dexOrderId);
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 200e6, "refund stranded internally");

        // R5 safe polarity: deleted order reads as fully filled -> swapper refuses to cancel-refund
        assertEq(limitAdapter.filledAmount(config, address(swapper), abi.encode(key)), 200e6);
        vm.expectRevert(BoringSwapper.BoringSwapper__OrderAlreadyFilled.selector);
        swapper.cancelOrder(orderId, config, "");

        // restore policy, then auth-gated rescue routes the principal to the VAULT only
        ITIP20Test(address(BASE)).changeTransferPolicyId(originalPolicy);

        vm.prank(makeAddr("rando"));
        vm.expectRevert("UNAUTHORIZED");
        manager.rescueStale(address(swapper), key, 200e6);

        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__RescueExceedsPrincipal.selector);
        manager.rescueStale(address(swapper), key, 200e6 + 1);

        manager.rescueStale(address(swapper), key, 200e6);
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore, "principal recovered to vault");
        assertTrue(manager.getOrderRecord(address(swapper), key).closed);

        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderClosed.selector);
        manager.rescueStale(address(swapper), key, 1);
    }

    // ============================================== Helpers ==============================================

    function _marketConfig(ERC20 tokenIn, ERC20 tokenOut, bytes memory swapData)
        internal
        view
        returns (ISwapperTypes.SwapConfig memory)
    {
        return ISwapperTypes.SwapConfig({
            tokenRoute: ISwapperTypes.TokenRoute(tokenIn, tokenOut),
            adapter: address(adapter),
            quoteAsset: address(QUOTE),
            swapData: swapData,
            slippageBps: 10,
            receiver: boringVault
        });
    }

    /// ask-shaped route (base -> quote) by default
    function _limitConfig(bool isBid, int16 tick, uint128 amount, bytes32 salt)
        internal
        view
        returns (ISwapperTypes.SwapConfig memory config, bytes32 key)
    {
        return _limitConfigRoute(isBid, tick, amount, salt, BASE, QUOTE);
    }

    function _limitConfigRoute(bool isBid, int16 tick, uint128 amount, bytes32 salt, ERC20 tokenIn, ERC20 tokenOut)
        internal
        view
        returns (ISwapperTypes.SwapConfig memory config, bytes32 key)
    {
        bytes memory swapData = abi.encode(
            DecoderCustomTypes.TempoLimitOrder({
                base: address(BASE), isBid: isBid, tick: tick, amount: amount, salt: uint256(salt)
            })
        );
        config = ISwapperTypes.SwapConfig({
            tokenRoute: ISwapperTypes.TokenRoute(tokenIn, tokenOut),
            adapter: address(limitAdapter),
            quoteAsset: address(QUOTE),
            swapData: swapData,
            slippageBps: 10,
            receiver: boringVault
        });
        key = keccak256(abi.encode(block.chainid, address(manager), swapData));
    }

    function _makeOracleConfig(address rateProvider) internal pure returns (BoringSwapper.RateProviderConfig memory) {
        address[] memory rateProviders = new address[](1);
        rateProviders[0] = rateProvider;
        address[] memory intermediaries = new address[](1);
        intermediaries[0] = address(0);
        return BoringSwapper.RateProviderConfig(rateProviders, intermediaries, false);
    }

    function _toArray(address addr) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }
}
