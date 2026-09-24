// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Minimal Safe (Gnosis Safe) v1.4.1 surface used by the spend module.
 * @dev Solid user accounts are Safe 1.4.1 smart accounts deployed through
 *      `permissionless`' `toSafeSmartAccount` (see solid-ui `hooks/useUser.ts`), so the
 *      spend module is a plain Safe module and moves value exclusively through
 *      `execTransactionFromModule`.
 */
interface ISafe {
    enum Operation {
        Call,
        DelegateCall
    }

    /**
     * @notice Executes a transaction from an enabled module, with no owner signatures.
     * @dev Returns false rather than bubbling the inner revert, which is why callers must
     *      additionally assert the observable effect of the call.
     */
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success);

    /**
     * @notice Whether `module` is currently enabled on this Safe.
     */
    function isModuleEnabled(address module) external view returns (bool);
}
