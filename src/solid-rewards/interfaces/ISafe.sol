// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice The slice of a Safe (v1.4.1) a module needs.
 *
 * `execTransactionFromModule` is the whole reason a module exists: it lets an
 * enabled module move the Safe's assets without a further owner signature. The
 * Safe itself checks `modules[msg.sender] != address(0)` on every call, so a
 * module whose consent has been withdrawn stops working on the very next block —
 * no off-chain poll can be as prompt, which is why nothing here caches it.
 *
 * `isModuleEnabled` is read only so a caller can *tell the user* the consent is
 * gone before spending gas on a call the Safe would reject anyway.
 */
interface ISafe {
    enum Operation {
        Call,
        DelegateCall
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success);

    function isModuleEnabled(address module) external view returns (bool);
}
