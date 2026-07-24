// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {TempoTestBase, ITIP20Test} from "test/adapters/TempoTestBase.sol";
import {BoringSwapper} from "src/base/Periphery/BoringSwapper.sol";
import {ISwapperTypes} from "src/interfaces/ISwapperTypes.sol";
import {TempoLimitOrderAdapter} from "src/base/Periphery/adapters/TempoLimitOrderAdapter.sol";
import {TempoLimitOrderManager} from "src/base/Periphery/TempoLimitOrderManager.sol";
import {ITempoLimitOrderManager} from "src/interfaces/ITempoLimitOrderManager.sol";
import {ITempoStablecoinDEX} from "src/interfaces/ITempoStablecoinDEX.sol";
import {TempoDexMath} from "src/helper/TempoDexMath.sol";
import {IAdapter} from "src/interfaces/IAdapter.sol";

/// @notice Full-stack fork tests for Tempo limit orders, the manager, and stale-order recovery.
contract TempoLimitOrderAdapterTest is TempoTestBase {
    // ======================================= Adapter rollout separation =======================================

    /// Each adapter serves exactly one flow, so limit orders can ship (or be paused)
    /// independently of market swaps via per-adapter approvals.
    function testAdapterSplit_FlowsAreMutuallyExclusive() external {
        // market adapter rejects the limit-order flow outright
        (ISwapperTypes.SwapConfig memory limitConfig,) = _limitConfig(false, 10, 200e6, "s1");
        limitConfig.adapter = address(adapter);
        vm.expectRevert(IAdapter.Adapter__LimitOrdersNotSupported.selector);
        swapper.submitOrder(limitConfig);

        // limit adapter mirrors no market selectors, so market swapData dies at pre-flight
        ISwapperTypes.SwapConfig memory marketConfig =
            _marketConfig(BASE, QUOTE, abi.encodeCall(DEX.swapExactAmountIn, (address(BASE), address(QUOTE), 500e6, 1)));
        marketConfig.adapter = address(limitAdapter);
        vm.expectRevert();
        swapper.swap(marketConfig);
    }

    // ======================================= verifyLimitOrder (unit) =======================================

    /// OrderInfo shape for an ask: escrow base exactly, conservative round-down output
    function testVerifyLimitOrder_Ask_OrderInfo() external view {
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
            abi.encodeCall(ITempoLimitOrderManager.placeOrder, (expectedKey, address(BASE), false, int16(10), uint128(100_000_001), address(boringVault))),
            "hookData places via manager"
        );
    }

    /// OrderInfo shape for a bid: escrow = ceil(amount * price) in quote — I6 rounding replication
    function testVerifyLimitOrder_Bid_EscrowRoundsUp() external view {
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
    function testVerifyLimitOrder_HashDeterminism() external view {
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

        ITempoLimitOrderManager.OrderRecord memory rec = manager.getOrderRecord(address(swapper), key);
        assertGt(rec.dexOrderId, 0, "order placed");
        assertEq(rec.receiver, address(boringVault));
        assertEq(rec.inputAmount, 200e6);
        assertFalse(rec.closed);

        ITempoStablecoinDEX.Order memory dexOrder = DEX.getOrder(rec.dexOrderId);
        assertEq(dexOrder.maker, address(manager), "manager is maker");
        assertEq(dexOrder.remaining, 200e6);
        assertEq(dexOrder.tick, 10);
        assertFalse(dexOrder.isBid);

        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 200e6);
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(BASE.balanceOf(address(swapper)), 0, "swapper wallet clean");

        assertEq(swapper.pendingOrderPrincipal(BASE), 200e6);
        assertEq(address(swapper.getOrderRecord(orderId).tokenIn), address(BASE));
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

    /// I6 round-trip: bid escrow uses ceil; cancelling refunds EXACTLY the escrow
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

        vm.prank(taker);
        DEX.swapExactAmountIn(address(QUOTE), address(BASE), 60e6, 59e6);

        assertEq(limitAdapter.filledAmount(config, address(swapper), abi.encode(key)), 60e6, "filled 60");

        vm.prank(keeper);
        uint128 proceeds = manager.harvest(address(swapper), key);
        assertEq(proceeds, 60e6);
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 60e6, "proceeds to vault");
        assertEq(QUOTE.balanceOf(keeper), 0, "keeper gets nothing");

        vm.prank(keeper);
        assertEq(manager.harvest(address(swapper), key), 0, "idempotent");

        swapper.cancelOrder(orderId, config, "");
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 60e6, "unfilled principal back");
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 60e6, "proceeds kept");
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");
    }

    /// same lifecycle on the bid side, where BOTH escrow and refund round (I6)
    function testLimitOrder_Bid_PartialFill_CancelHarvestsAndRefundsExactly() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfigRoute(true, 10, 200e6, "s1", QUOTE, BASE);
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);
        uint256 escrow = 200e6 * 100_010 / 100_000;

        vm.prank(taker);
        DEX.swapExactAmountIn(address(BASE), address(QUOTE), 60e6, 1);

        uint256 filled = limitAdapter.filledAmount(config, address(swapper), abi.encode(key));
        assertEq(filled, 60e6 * 100_010 / 100_000, "filled input in quote units");

        swapper.cancelOrder(orderId, config, "");

        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore + 60e6, "base proceeds harvested");
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore - escrow + (escrow - filled), "exact quote refund");
        assertEq(DEX.balanceOf(address(manager), address(QUOTE)), 0, "manager internal clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");
    }

    /// state transition OPEN -> FILLED: filledAmount == inputAmount blocks cancel; harvest delivers all proceeds
    function testLimitOrder_FullFill_BlocksCancelAndHarvests() external {
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 0, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);

        vm.prank(taker);
        DEX.swapExactAmountIn(address(QUOTE), address(BASE), 200e6, 199e6);

        assertEq(limitAdapter.filledAmount(config, address(swapper), abi.encode(key)), 200e6);

        vm.expectRevert(BoringSwapper.BoringSwapper__OrderAlreadyFilled.selector);
        swapper.cancelOrder(orderId, config, "");

        vm.prank(keeper);
        manager.harvest(address(swapper), key);
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 200e6, "all proceeds to vault");

        swapper.releaseFee(orderId);
        assertEq(swapper.pendingOrderPrincipal(BASE), 0);
    }

    /// duplicate-hash protection lives in the swapper and keys off our deterministic hash
    function testSubmitLimitOrder_DuplicateHashRejected() external {
        (ISwapperTypes.SwapConfig memory config,) = _limitConfig(false, 10, 200e6, "s1");
        swapper.submitOrder(config);

        vm.expectRevert(BoringSwapper.BoringSwapper__DuplicateOrder.selector);
        swapper.submitOrder(config);

        (ISwapperTypes.SwapConfig memory config2,) = _limitConfig(false, 10, 200e6, "s2");
        swapper.submitOrder(config2);
    }

    /// failure path §4.8: submission-time fat-finger bound
    function testSubmitLimitOrder_PriceValidatorFatFinger() external {
        (ISwapperTypes.SwapConfig memory config,) = _limitConfig(false, -200, 200e6, "s1");
        vm.expectRevert();
        swapper.submitOrder(config);
    }

    // =========================================== Manager (unit) ===========================================

    function testManager_PlaceOrder_Guards() external {
        ITIP20Test(address(BASE)).mint(address(this), 500e6);
        BASE.approve(address(manager), type(uint256).max);
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__NotSwapper.selector);
        manager.placeOrder("k", address(BASE), false, 10, 200e6, address(boringVault));

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

        vm.prank(makeAddr("rando"));
        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderNotFound.selector);
        manager.cancelOrder(key);

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

    /// walletBuffer accounting: internal proceeds can fund a later placement before wallet escrow
    function testManager_WalletBuffer_InternalBalanceConsumedAtPlace() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory bidConfig, bytes32 bidKey) = _limitConfigRoute(true, 0, 150e6, "bid", QUOTE, BASE);
        swapper.submitOrder(bidConfig);

        vm.prank(taker);
        DEX.swapExactAmountIn(address(BASE), address(QUOTE), 150e6, 1);
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 150e6, "unharvested internal proceeds");

        (ISwapperTypes.SwapConfig memory askConfig,) = _limitConfig(false, 0, 120e6, "ask");
        uint256 askOrderId = swapper.orders();
        swapper.submitOrder(askConfig);

        assertEq(manager.walletBuffer(address(BASE)), 120e6, "displaced escrow tracked");
        assertEq(BASE.balanceOf(address(manager)), 120e6, "escrow left in wallet");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 30e6, "internal reduced");

        vm.prank(keeper);
        manager.harvest(address(swapper), bidKey);
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 120e6 + 150e6, "order1 proceeds intact");
        assertEq(manager.walletBuffer(address(BASE)), 0, "buffer drained");
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");

        swapper.cancelOrder(askOrderId, askConfig, "");
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore + 150e6, "order2 escrow intact");
        assertEq(BASE.balanceOf(address(manager)), 0, "manager wallet clean");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");
    }

    // ============================================ Stale-cancel ============================================

    /// R5/STRANDED path end-to-end: stale cancellation followed by rescue recovers principal
    function testStaleCancel_RescueFlow() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 10, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);
        uint128 dexOrderId = manager.getOrderRecord(address(swapper), key).dexOrderId;

        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderStillActive.selector);
        manager.rescueStale(address(swapper), key, 200e6);

        uint64 originalPolicy = ITIP20Test(address(BASE)).transferPolicyId();
        uint64 blockPolicy = REGISTRY_403.createPolicy(address(this), POLICY_BLACKLIST);
        REGISTRY_403.modifyPolicyBlacklist(blockPolicy, address(manager), true);
        ITIP20Test(address(BASE)).changeTransferPolicyId(blockPolicy);

        vm.prank(makeAddr("rando"));
        DEX.cancelStaleOrder(dexOrderId);
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 200e6, "refund stranded internally");

        assertEq(limitAdapter.filledAmount(config, address(swapper), abi.encode(key)), 200e6);
        vm.expectRevert(BoringSwapper.BoringSwapper__OrderAlreadyFilled.selector);
        swapper.cancelOrder(orderId, config, "");

        ITIP20Test(address(BASE)).changeTransferPolicyId(originalPolicy);

        vm.prank(makeAddr("rando"));
        vm.expectRevert("UNAUTHORIZED");
        manager.rescueStale(address(swapper), key, 0);

        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__RescueExceedsUnattributed.selector);
        manager.rescueStale(address(swapper), key, 200e6 + 1);

        manager.rescueStale(address(swapper), key, 0);
        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore, "principal recovered to vault");
        assertTrue(manager.getOrderRecord(address(swapper), key).closed);
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "manager internal clean");

        vm.expectRevert(TempoLimitOrderManager.TempoLimitOrderManager__OrderClosed.selector);
        manager.rescueStale(address(swapper), key, 0);
    }

    /// Partial fill, harvest, more fills, stale-cancel, then conservation-based rescue.
    function testStaleCancel_PartialFill_RescueRecoversBothLegs() external {
        uint256 vaultBaseBefore = BASE.balanceOf(address(boringVault));
        uint256 vaultQuoteBefore = QUOTE.balanceOf(address(boringVault));

        (ISwapperTypes.SwapConfig memory config, bytes32 key) = _limitConfig(false, 0, 200e6, "s1");
        uint256 orderId = swapper.orders();
        swapper.submitOrder(config);
        uint128 dexOrderId = manager.getOrderRecord(address(swapper), key).dexOrderId;

        vm.prank(taker);
        DEX.swapExactAmountIn(address(QUOTE), address(BASE), 30e6, 29e6);
        vm.prank(keeper);
        assertEq(manager.harvest(address(swapper), key), 30e6, "first fill harvested");
        vm.prank(taker);
        DEX.swapExactAmountIn(address(QUOTE), address(BASE), 60e6, 59e6);

        uint64 originalPolicy = ITIP20Test(address(BASE)).transferPolicyId();
        uint64 blockPolicy = REGISTRY_403.createPolicy(address(this), POLICY_BLACKLIST);
        REGISTRY_403.modifyPolicyBlacklist(blockPolicy, address(manager), true);
        ITIP20Test(address(BASE)).changeTransferPolicyId(blockPolicy);
        vm.prank(makeAddr("rando"));
        DEX.cancelStaleOrder(dexOrderId);

        assertEq(DEX.balanceOf(address(manager), address(BASE)), 110e6, "remainder refund stranded");
        assertEq(DEX.balanceOf(address(manager), address(QUOTE)), 60e6, "fill proceeds stranded");

        vm.prank(keeper);
        vm.expectRevert(ITempoStablecoinDEX.InsufficientBalance.selector);
        manager.harvest(address(swapper), key);

        vm.expectRevert(BoringSwapper.BoringSwapper__OrderAlreadyFilled.selector);
        swapper.cancelOrder(orderId, config, "");

        ITIP20Test(address(BASE)).changeTransferPolicyId(originalPolicy);
        manager.rescueStale(address(swapper), key, 60e6);

        assertEq(BASE.balanceOf(address(boringVault)), vaultBaseBefore - 200e6 + 110e6, "refund leg exact");
        assertEq(QUOTE.balanceOf(address(boringVault)), vaultQuoteBefore + 30e6 + 60e6, "proceeds legs exact");
        assertEq(DEX.balanceOf(address(manager), address(BASE)), 0, "no residue");
        assertEq(DEX.balanceOf(address(manager), address(QUOTE)), 0, "no residue");
        assertTrue(manager.getOrderRecord(address(swapper), key).closed);
    }
}
