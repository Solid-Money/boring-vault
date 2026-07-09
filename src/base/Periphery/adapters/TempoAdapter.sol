// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {ISwapperTypes} from "src/interfaces/ISwapperTypes.sol";
import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {IAdapter} from "src/interfaces/IAdapter.sol";
import {BaseAdapter} from "src/base/Periphery/adapters/BaseAdapter.sol";
import {ITempoStablecoinDEX, ITIP20} from "src/interfaces/ITempoStablecoinDEX.sol";
import {ITempoLimitOrderManager} from "src/interfaces/ITempoLimitOrderManager.sol";
import {TempoDexMath} from "src/helper/TempoDexMath.sol";

/// @notice Adapter for Tempo's native stablecoin DEX (the TIP-20 exchange predeploy).
///
/// Market orders mirror the DEX's two taker selectors. The DEX has no recipient parameter —
/// output tokens are transferred to the caller, which is the swapper, so the post-flight
/// balance-delta check works unmodified. Routing (direct pair or multi-hop through quote
/// tokens / pathUSD) happens inside the DEX; the adapter only pins the route endpoints.
/// This adapter MUST NOT mirror any other DEX selector (place/placeFlip/withdraw/cancel/
/// createPair): a match would let the market-swap flow execute maker/balance operations and
/// strand funds in the DEX's internal balance.
///
/// Limit orders are placed through the TempoLimitOrderManager (maker-of-record), because the
/// DEX settles maker refunds and fill proceeds into an internal DEX balance that only the maker
/// can withdraw. approvalTarget/cancelTarget/hook all point at the manager.
contract TempoAdapter is IAdapter, BaseAdapter {
    //============================== Errors ===============================

    error TempoAdapter__BelowMinimumOrderSize();
    error TempoAdapter__OrderNotFound();

    //============================== Immutables ===============================

    /// @notice Tempo stablecoin DEX predeploy.
    address public immutable TEMPO_DEX;
    /// @notice Maker-of-record for limit orders.
    address public immutable MANAGER;

    constructor(address _tempoDex, address _manager) {
        TEMPO_DEX = _tempoDex;
        MANAGER = _manager;
    }

    //============================== Market Orders ===============================

    /// @notice Mirrors ITempoStablecoinDEX.swapExactAmountIn — sell a fixed input amount.
    function swapExactAmountIn(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 /*minAmountOut*/
    )
        external
        view
        returns (address, uint256)
    {
        ISwapperTypes.SwapConfig memory swapConfig = _getAppendedSwapConfig();
        if (ERC20(tokenIn) != swapConfig.tokenRoute.tokenIn) revert Adapter__TokenInMismatch();
        if (ERC20(tokenOut) != swapConfig.tokenRoute.tokenOut) revert Adapter__TokenOutMismatch();

        return (TEMPO_DEX, amountIn);
    }

    /// @notice Mirrors ITempoStablecoinDEX.swapExactAmountOut — buy a fixed output amount.
    /// @dev maxAmountIn is the pull/approval amount; the DEX only draws the computed input and
    ///      the swapper returns unspent tokenIn to the vault as dust. The price validator and
    ///      rate limiter both see maxAmountIn — the conservative direction.
    function swapExactAmountOut(
        address tokenIn,
        address tokenOut,
        uint128,
        /*amountOut*/
        uint128 maxAmountIn
    )
        external
        view
        returns (address, uint256)
    {
        ISwapperTypes.SwapConfig memory swapConfig = _getAppendedSwapConfig();
        if (ERC20(tokenIn) != swapConfig.tokenRoute.tokenIn) revert Adapter__TokenInMismatch();
        if (ERC20(tokenOut) != swapConfig.tokenRoute.tokenOut) revert Adapter__TokenOutMismatch();

        return (TEMPO_DEX, maxAmountIn);
    }

    //============================== Limit Orders ===============================

    /// @notice swapData encoding: abi.encode(DecoderCustomTypes.TempoLimitOrder).
    /// @dev Deterministic — recomputable at cancel time: the protocol hash reads no live chain
    ///      state, only (chainid, manager, swapData). Orders are single-hop by construction: the
    ///      route must be exactly {base, quoteToken(base)} in the direction implied by isBid.
    function verifyLimitOrder(
        ISwapperTypes.SwapConfig calldata swapConfig,
        address /*swapper*/
    )
        external
        view
        returns (OrderInfo memory)
    {
        DecoderCustomTypes.TempoLimitOrder memory order =
            abi.decode(swapConfig.swapData, (DecoderCustomTypes.TempoLimitOrder));

        TempoDexMath.validateTick(order.tick);
        if (order.amount < TempoDexMath.MIN_ORDER_AMOUNT) revert TempoAdapter__BelowMinimumOrderSize();

        (address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount) = _orderAmounts(order);

        if (ERC20(inputToken) != swapConfig.tokenRoute.tokenIn) revert Adapter__TokenInMismatch();
        if (ERC20(outputToken) != swapConfig.tokenRoute.tokenOut) revert Adapter__TokenOutMismatch();

        bytes32 key = keccak256(abi.encode(block.chainid, MANAGER, swapConfig.swapData));

        return OrderInfo({
            approvalTarget: MANAGER,
            cancelTarget: MANAGER,
            inputToken: inputToken,
            outputToken: outputToken,
            inputAmount: inputAmount,
            outputAmount: outputAmount,
            protocolHash: key,
            hook: MANAGER,
            hookData: _placeCalldata(order, key, address(swapConfig.receiver)),
            context: abi.encode(key)
        });
    }

    /// @dev bid: pay quote to buy base; ask: sell base for quote. `amount` is base units, so the
    ///      escrow (inputAmount) replicates the precompile's rounding: bids escrow quote rounded
    ///      UP; asks escrow base exactly. Ask output uses the conservative round-DOWN estimate
    ///      (realized proceeds round up per fill).
    function _orderAmounts(DecoderCustomTypes.TempoLimitOrder memory order)
        internal
        view
        returns (address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount)
    {
        address quote = ITIP20(order.base).quoteToken();
        return order.isBid
            ? (quote, order.base, uint256(TempoDexMath.baseToQuoteUp(order.amount, order.tick)), uint256(order.amount))
            : (
                order.base,
                quote,
                uint256(order.amount),
                uint256(TempoDexMath.baseToQuoteDown(order.amount, order.tick))
            );
    }

    function _placeCalldata(DecoderCustomTypes.TempoLimitOrder memory order, bytes32 key, address receiver)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            ITempoLimitOrderManager.placeOrder, (key, order.base, order.isBid, order.tick, order.amount, receiver)
        );
    }

    /// @dev The manager (maker-of-record) handles the gone-order case without reverting, per the
    ///      IAdapter cancel contract: the swapper-side cancel must complete even if the DEX order
    ///      no longer exists.
    function cancelLimitOrder(
        ISwapperTypes.SwapConfig calldata,
        /*swapConfig*/
        address,
        /*swapper*/
        bytes calldata,
        /*cancelData*/
        bytes calldata context
    )
        external
        view
        returns (address, bytes memory)
    {
        bytes32 key = abi.decode(context, (bytes32));
        return (MANAGER, abi.encodeCall(ITempoLimitOrderManager.cancelOrder, (key)));
    }

    /// @notice Escrow-token units filled so far, defined so that `inputAmount - filledAmount`
    ///         equals EXACTLY the refund the DEX credits on cancel (same rounding direction).
    /// @dev A deleted DEX order (getOrder reverts) is reported as FULLY FILLED. This is the safe
    ///      polarity: deletion is ambiguous between full fill and a stale-cancel (third-party
    ///      cancel while the manager is TIP-403-blocked), and under-reporting fills would permit
    ///      an over-refund from the swapper's escrow. Stranded stale-cancel principal is
    ///      recovered via the manager's auth-gated rescueStale instead.
    function filledAmount(ISwapperTypes.SwapConfig calldata swapConfig, address swapper, bytes calldata context)
        external
        view
        returns (uint256)
    {
        DecoderCustomTypes.TempoLimitOrder memory order =
            abi.decode(swapConfig.swapData, (DecoderCustomTypes.TempoLimitOrder));
        bytes32 key = abi.decode(context, (bytes32));

        ITempoLimitOrderManager.OrderRecord memory record =
            ITempoLimitOrderManager(MANAGER).getOrderRecord(swapper, key);
        if (record.dexOrderId == 0) revert TempoAdapter__OrderNotFound();

        try ITempoStablecoinDEX(TEMPO_DEX).getOrder(record.dexOrderId) returns (
            ITempoStablecoinDEX.Order memory dexOrder
        ) {
            if (order.isBid) {
                // escrow was ceil(amount * price); the cancel refund is ceil(remaining * price)
                return TempoDexMath.baseToQuoteUp(order.amount, order.tick)
                    - TempoDexMath.baseToQuoteUp(dexOrder.remaining, order.tick);
            }
            return order.amount - dexOrder.remaining;
        } catch {
            // order deleted — resolve toward "fully filled" (never toward over-refund)
            return order.isBid ? TempoDexMath.baseToQuoteUp(order.amount, order.tick) : order.amount;
        }
    }

    function version() external pure returns (string memory) {
        return "v1";
    }
}
