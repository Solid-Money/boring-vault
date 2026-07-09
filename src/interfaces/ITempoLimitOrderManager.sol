// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

/// @notice Maker-of-record for BoringSwapper limit orders on the Tempo stablecoin DEX.
///         Bridges the DEX's internal-balance settlement model to the swapper's wallet-custody
///         model: refunds are paid to the order owner (the swapper), proceeds to the recorded
///         receiver (the vault).
interface ITempoLimitOrderManager {
    struct OrderRecord {
        /// @notice DEX-assigned order id (non-zero marks the record as existing)
        uint128 dexOrderId;
        /// @notice destination for fill proceeds and rescues (the BoringVault)
        address receiver;
        /// @notice base token of the DEX pair (order `amount` denomination)
        address base;
        /// @notice quote token of the DEX pair
        address quote;
        /// @notice bid = buying base with quote; ask = selling base for quote
        bool isBid;
        /// @notice set once the order is cancelled or rescued; terminal
        bool closed;
        int16 tick;
        /// @notice original order amount in base units
        uint128 amount;
        /// @notice escrow pulled from the owner at placement (quote for bids, base for asks)
        uint128 inputAmount;
        /// @notice base units already attributed and paid out by harvest
        uint128 harvestedBase;
    }

    function placeOrder(bytes32 key, address base, bool isBid, int16 tick, uint128 amount, address receiver)
        external
        returns (uint128 dexOrderId);

    function harvest(address owner, bytes32 key) external returns (uint128 proceeds);

    function cancelOrder(bytes32 key) external returns (uint128 refund);

    function rescueStale(address owner, bytes32 key, uint128 refundAmount) external;

    function getOrderRecord(address owner, bytes32 key) external view returns (OrderRecord memory);
}
