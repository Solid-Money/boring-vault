// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";

/**
 * @notice The slice of `TellerWithMultiAssetSupport` a zap needs.
 *
 * Declared here rather than importing the Teller itself, which drags in the
 * vault, the accountant, the pauser and half of `Roles/` for one function
 * signature — and would pin this contract to a Teller version it does not
 * otherwise care about.
 *
 * `deposit` mints to `msg.sender`, which is the whole reason the zap exists:
 * a Safe that wants soFUSE locked in the same transaction it deposits cannot
 * name the lock as the recipient, and cannot read its own new balance
 * mid-batch to lock the right amount.
 */
interface ITeller {
    /**
     * @param depositAsset the asset to deposit, or the native sentinel
     *        `0xEeee…EEeE` with the amount sent as `msg.value`.
     * @param depositAmount ignored for a native deposit, which uses `msg.value`.
     * @param minimumMint the fewest shares the caller will accept.
     */
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint)
        external
        payable
        returns (uint256 shares);

    /**
     * @notice The BoringVault this Teller mints for — and the spender to approve.
     */
    function vault() external view returns (address);

    /**
     * @notice The wrapped native token the Teller wraps a native deposit into.
     */
    function nativeWrapper() external view returns (address);
}
