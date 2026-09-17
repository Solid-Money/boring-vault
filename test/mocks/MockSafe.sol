// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ISafe} from "src/solid-rewards/interfaces/ISafe.sol";

/**
 * @notice The part of a Safe that a module actually meets.
 *
 * Only the two calls `SolidSubscriptionModule` makes, with the one rule that
 * matters reproduced faithfully: `execTransactionFromModule` refuses a caller
 * that is not an enabled module, which is what makes `disableModule` an instant
 * revocation rather than a request.
 */
contract MockSafe {
    mapping(address => bool) public modules;

    error MockSafe__NotAModule(address caller);

    function enableModule(address module) external {
        modules[module] = true;
    }

    function disableModule(address module) external {
        modules[module] = false;
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return modules[module];
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, ISafe.Operation)
        external
        returns (bool success)
    {
        if (!modules[msg.sender]) revert MockSafe__NotAModule(msg.sender);

        (success,) = to.call{value: value}(data);
    }

    /// @notice Lets a test drive the Safe's own calls, e.g. `subscribe`.
    function execute(address to, bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = to.call(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        return result;
    }

    receive() external payable {}
}
