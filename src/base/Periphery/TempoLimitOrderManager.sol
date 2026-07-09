// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {ITempoStablecoinDEX, ITIP20} from "src/interfaces/ITempoStablecoinDEX.sol";
import {ITempoLimitOrderManager} from "src/interfaces/ITempoLimitOrderManager.sol";
import {TempoDexMath} from "src/helper/TempoDexMath.sol";

/// @notice Maker-of-record for BoringSwapper limit orders on the Tempo stablecoin DEX.
///
/// The DEX credits maker fill proceeds and cancel refunds to an INTERNAL DEX balance that only
/// the maker can `withdraw()`, and its cancel path cannot be combined with a withdraw in the
/// single external call the swapper's cancel flow permits. This contract is therefore the DEX
/// maker: it escrows on behalf of an order owner (a BoringSwapper), tracks per-order fill
/// attribution, and routes funds to exactly two destinations — principal refunds to the owner
/// (whose own cancel flow forwards them to the vault) and fill proceeds to the recorded
/// receiver (the vault).
///
/// Trust/permission model:
/// - `placeOrder` is permissionless; a record binds the caller's own funds to the caller.
/// - `harvest` is permissionless; it can only pay `record.receiver`.
/// - `cancelOrder` is owner-only (the swapper calls it via the adapter's cancelTarget).
/// - `rescueStale` is auth-gated and can only pay `record.receiver`.
contract TempoLimitOrderManager is ITempoLimitOrderManager, Auth, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    //============================== Errors ===============================

    error TempoLimitOrderManager__KeyAlreadyUsed();
    error TempoLimitOrderManager__OrderNotFound();
    error TempoLimitOrderManager__OrderClosed();
    error TempoLimitOrderManager__InvalidReceiver();
    error TempoLimitOrderManager__RefundShortfall(uint128 measured, uint128 expected);
    error TempoLimitOrderManager__OrderStillActive();
    error TempoLimitOrderManager__RescueExceedsPrincipal();

    //============================== Events ===============================

    event TempoOrderPlaced(
        address indexed owner,
        bytes32 indexed key,
        uint128 indexed dexOrderId,
        address base,
        bool isBid,
        int16 tick,
        uint128 amount,
        uint128 inputAmount,
        address receiver
    );
    event TempoOrderHarvested(
        address indexed owner, bytes32 indexed key, address token, uint128 proceeds, address receiver
    );
    event TempoOrderCancelled(address indexed owner, bytes32 indexed key, address token, uint128 refund);
    event TempoOrderRescued(
        address indexed owner, bytes32 indexed key, address token, uint128 amount, address receiver
    );

    //============================== Immutables ===============================

    ITempoStablecoinDEX public immutable tempoDex;

    //============================== State ===============================

    /// @notice order records keyed by (owner, protocolHash-derived key)
    mapping(address owner => mapping(bytes32 key => OrderRecord)) internal orders;

    /// @notice Portion of this contract's WALLET balance that belongs to internal-balance
    ///         accounting. The DEX consumes the maker's internal balance BEFORE pulling wallet
    ///         funds on `place`, so escrow we pulled into the wallet can be left behind while
    ///         pre-existing internal credit (unharvested proceeds) is consumed instead. Tracking
    ///         that displaced amount here keeps `walletBuffer[token] + dex.balanceOf(this, token)`
    ///         equal to the total attributable to open orders, and payouts draw from the buffer
    ///         before withdrawing from the DEX.
    mapping(address token => uint128) public walletBuffer;

    //============================== Constructor ===============================

    constructor(address _tempoDex, address _owner, Authority _authority) Auth(_owner, _authority) {
        tempoDex = ITempoStablecoinDEX(_tempoDex);
    }

    //============================== Order Lifecycle ===============================

    /// @notice Escrows from the caller and places a limit order on the DEX with this contract as
    ///         maker. Called by the swapper as the submit-time hook; `msg.sender` is the record
    ///         owner and the only address `cancelOrder` will honor for `key`.
    /// @param key       unique identifier (the adapter uses the swapper protocolHash)
    /// @param base      base token of the pair; `amount` is denominated in it
    /// @param isBid     true = buy base with quote (escrow quote), false = sell base (escrow base)
    /// @param tick      limit price tick; must be aligned and within the DEX band
    /// @param amount    order size in base units
    /// @param receiver  destination for fill proceeds (the vault)
    function placeOrder(bytes32 key, address base, bool isBid, int16 tick, uint128 amount, address receiver)
        external
        nonReentrant
        returns (uint128 dexOrderId)
    {
        if (orders[msg.sender][key].dexOrderId != 0) revert TempoLimitOrderManager__KeyAlreadyUsed();
        if (receiver == address(0)) revert TempoLimitOrderManager__InvalidReceiver();
        TempoDexMath.validateTick(tick);

        address quote = ITIP20(base).quoteToken();
        uint128 escrowAmount;
        (dexOrderId, escrowAmount) = _escrowAndPlace(base, quote, isBid, tick, amount);

        orders[msg.sender][key] = OrderRecord({
            dexOrderId: dexOrderId,
            receiver: receiver,
            base: base,
            quote: quote,
            isBid: isBid,
            closed: false,
            tick: tick,
            amount: amount,
            inputAmount: escrowAmount,
            harvestedBase: 0
        });

        emit TempoOrderPlaced(msg.sender, key, dexOrderId, base, isBid, tick, amount, escrowAmount, receiver);
    }

    /// @dev Pulls the escrow from the caller and places the order on the DEX.
    function _escrowAndPlace(address base, address quote, bool isBid, int16 tick, uint128 amount)
        internal
        returns (uint128 dexOrderId, uint128 escrowAmount)
    {
        address escrowToken;
        (escrowToken, escrowAmount) = isBid ? (quote, TempoDexMath.baseToQuoteUp(amount, tick)) : (base, amount);

        ERC20(escrowToken).safeTransferFrom(msg.sender, address(this), escrowAmount);

        // The DEX pulls escrow via transferFrom, but consumes this contract's internal DEX
        // balance first. Snapshot it so any consumed internal credit (unharvested proceeds of
        // other orders) is re-attributed to the wallet funds it left behind (see walletBuffer).
        uint128 internalBefore = tempoDex.balanceOf(address(this), escrowToken);

        ERC20(escrowToken).safeApprove(address(tempoDex), escrowAmount);
        dexOrderId = tempoDex.place(base, amount, isBid, tick);
        // reset any allowance the DEX did not consume (it consumed internal balance instead)
        ERC20(escrowToken).safeApprove(address(tempoDex), 0);

        uint128 internalConsumed = internalBefore - tempoDex.balanceOf(address(this), escrowToken);
        if (internalConsumed > 0) walletBuffer[escrowToken] += internalConsumed;
    }

    /// @notice Pays out any newly-filled proceeds for an order to its recorded receiver.
    ///         Permissionless: fills accrue to this contract's internal DEX balance
    ///         continuously and someone must claim them; the destination is fixed.
    function harvest(address owner, bytes32 key) external nonReentrant returns (uint128 proceeds) {
        OrderRecord storage record = orders[owner][key];
        if (record.dexOrderId == 0) revert TempoLimitOrderManager__OrderNotFound();
        if (record.closed) revert TempoLimitOrderManager__OrderClosed();
        (proceeds,) = _harvest(owner, key, record);
    }

    /// @notice Cancels the caller's order: harvests outstanding proceeds to the receiver, cancels
    ///         on the DEX, and pays the principal refund to the CALLER's wallet — the swapper's
    ///         own cancel flow then forwards exactly `inputAmount - filledAmount` to the vault.
    /// @dev Never reverts for an order that is already gone on the DEX (fully filled or
    ///      stale-cancelled): per the IAdapter cancel contract the swapper-side cancel must still
    ///      be able to complete; in that case the refund is 0. Fill state is read atomically in
    ///      this transaction — never cached — and the refund paid is checked against the measured
    ///      internal-balance delta from the DEX cancel (never against computed rounding alone).
    function cancelOrder(bytes32 key) external nonReentrant returns (uint128 refund) {
        OrderRecord storage record = orders[msg.sender][key];
        if (record.dexOrderId == 0) revert TempoLimitOrderManager__OrderNotFound();
        if (record.closed) revert TempoLimitOrderManager__OrderClosed();

        (, uint128 remaining) = _harvest(msg.sender, key, record);
        record.closed = true;

        address escrowToken = record.isBid ? record.quote : record.base;
        if (remaining == 0) {
            // order already deleted on the DEX (fully filled, or stale-cancelled — the swapper
            // blocks the latter via filledAmount, see adapter); nothing to cancel or refund
            emit TempoOrderCancelled(msg.sender, key, escrowToken, 0);
            return 0;
        }

        refund = record.isBid ? TempoDexMath.baseToQuoteUp(remaining, record.tick) : remaining;

        // Measured-refund invariant (I6a): the DEX credits the refund to our internal balance;
        // verify the actual delta covers what we pay out rather than trusting recomputed rounding.
        uint128 internalBefore = tempoDex.balanceOf(address(this), escrowToken);
        tempoDex.cancel(record.dexOrderId);
        uint128 measured = tempoDex.balanceOf(address(this), escrowToken) - internalBefore;
        if (measured < refund) revert TempoLimitOrderManager__RefundShortfall(measured, refund);

        _payout(escrowToken, refund, msg.sender);

        emit TempoOrderCancelled(msg.sender, key, escrowToken, refund);
    }

    /// @notice Recovery for stale-cancelled orders (third party called the DEX's
    ///         `cancelStaleOrder` while this contract was blocked by a TIP-403 policy): the
    ///         escrow refund sits in this contract's internal DEX balance with no record-driven
    ///         path out. Auth determines `refundAmount` from DEX events off-chain; funds can only
    ///         go to the order's recorded receiver.
    function rescueStale(address owner, bytes32 key, uint128 refundAmount) external requiresAuth {
        OrderRecord storage record = orders[owner][key];
        if (record.dexOrderId == 0) revert TempoLimitOrderManager__OrderNotFound();
        if (record.closed) revert TempoLimitOrderManager__OrderClosed();
        if (refundAmount > record.inputAmount) revert TempoLimitOrderManager__RescueExceedsPrincipal();
        // only orders the DEX has already deleted can be rescued
        if (_remainingOf(record.dexOrderId) != 0) revert TempoLimitOrderManager__OrderStillActive();

        record.closed = true;
        address escrowToken = record.isBid ? record.quote : record.base;
        _payout(escrowToken, refundAmount, record.receiver);

        emit TempoOrderRescued(owner, key, escrowToken, refundAmount, record.receiver);
    }

    //============================== Views ===============================

    function getOrderRecord(address owner, bytes32 key) external view returns (OrderRecord memory) {
        return orders[owner][key];
    }

    //============================== Internal ===============================

    /// @dev Attributes newly-filled base since the last harvest and pays the corresponding
    ///      proceeds to the receiver. Returns the live remaining amount (0 if the DEX order is
    ///      deleted). Proceeds for asks use aggregate ceil, which never exceeds the sum of the
    ///      DEX's per-fill ceil credits — attribution can only under-claim (dust stays internal).
    function _harvest(address owner, bytes32 key, OrderRecord storage record)
        internal
        returns (uint128 proceeds, uint128 remaining)
    {
        remaining = _remainingOf(record.dexOrderId);

        uint128 filledBase = record.amount - remaining;
        uint128 delta = filledBase - record.harvestedBase;
        if (delta == 0) return (0, remaining);
        record.harvestedBase = filledBase;

        // bid maker is credited base 1:1; ask maker is credited quote at ceil(fill * price)
        address token;
        (token, proceeds) =
            record.isBid ? (record.base, delta) : (record.quote, TempoDexMath.baseToQuoteUp(delta, record.tick));

        _payout(token, proceeds, record.receiver);

        emit TempoOrderHarvested(owner, key, token, proceeds, record.receiver);
    }

    /// @dev Live remaining base of a DEX order; 0 when the order is deleted (fully filled or
    ///      cancelled — `getOrder` reverts OrderDoesNotExist for both).
    function _remainingOf(uint128 dexOrderId) internal view returns (uint128) {
        try tempoDex.getOrder(dexOrderId) returns (ITempoStablecoinDEX.Order memory order) {
            return order.remaining;
        } catch {
            return 0;
        }
    }

    /// @dev Pays `amount` of `token` to `to`, drawing from the wallet buffer first (funds
    ///      displaced by internal-balance consumption at place time) and withdrawing the
    ///      remainder from this contract's internal DEX balance. The DEX withdraw reverts on
    ///      insufficient internal balance, which fails closed if attribution is ever inconsistent
    ///      (e.g. after a stale-cancel) instead of silently drawing on other orders' funds.
    function _payout(address token, uint128 amount, address to) internal {
        if (amount == 0) return;
        uint128 buffered = walletBuffer[token];
        uint128 fromBuffer = buffered < amount ? buffered : amount;
        if (fromBuffer > 0) walletBuffer[token] = buffered - fromBuffer;
        uint128 fromDex = amount - fromBuffer;
        if (fromDex > 0) tempoDex.withdraw(token, fromDex);
        ERC20(token).safeTransfer(to, amount);
    }
}
