// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ISafe} from "src/solid-rewards/interfaces/ISafe.sol";

/**
 * @notice A contract that answers a module the way a Safe would, and pays nothing.
 *
 * The attack the audit described: the module's only pre-flight is
 * `isModuleEnabled`, and its only settlement signal is the boolean
 * `execTransactionFromModule` returns — both of them read from the address
 * being charged. A contract that returns `true` from each, holds a billing
 * token balance so `canCharge` sees funds, and simply does not forward the
 * transfer, collects a `Charged` receipt and burns a billing id for free.
 *
 * Deliberately keeps its balance: the point is that a balance check is not a
 * settlement check.
 */
contract MockCounterfeitSafe {
    /// @notice Always yes, for any module, without ever having enabled one.
    function isModuleEnabled(address) external pure returns (bool) {
        return true;
    }

    /// @notice Reports success and moves nothing.
    function execTransactionFromModule(address, uint256, bytes calldata, ISafe.Operation)
        external
        pure
        returns (bool)
    {
        return true;
    }

    /// @notice Lets a test drive this contract's own calls, e.g. `subscribe`.
    function execute(address to, bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = to.call(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        return result;
    }
}
