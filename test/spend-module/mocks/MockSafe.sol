// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ISafe} from "src/spend-module/interfaces/ISafe.sol";

/**
 * @notice Minimal stand-in for Safe 1.4.1's module-execution surface.
 * @dev Reproduces the two behaviours the spend module actually depends on: an enabled-module
 *      registry, and `execTransactionFromModule` returning `false` on inner failure rather than
 *      bubbling the revert. The latter is exactly the trap `SolidCashModule.spend` guards against
 *      with its balance-delta assertion, so the mock must not "helpfully" bubble.
 */
contract MockSafe {
    mapping(address => bool) public isModuleEnabled;

    /// @notice Forces `execTransactionFromModule` to report failure, for testing the failure path.
    bool public execAlwaysFails;

    /// @notice Swallows the inner call entirely but still reports success, simulating a Safe or
    ///         token that lies about the transfer having happened.
    bool public execLiesAboutSuccess;

    function enableModule(address module) external {
        isModuleEnabled[module] = true;
    }

    function disableModule(address module) external {
        isModuleEnabled[module] = false;
    }

    function setExecAlwaysFails(bool value) external {
        execAlwaysFails = value;
    }

    function setExecLiesAboutSuccess(bool value) external {
        execLiesAboutSuccess = value;
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, ISafe.Operation)
        external
        returns (bool success)
    {
        if (execAlwaysFails) return false;
        if (execLiesAboutSuccess) return true;

        (success,) = to.call{value: value}(data);
    }

    receive() external payable {}
}
