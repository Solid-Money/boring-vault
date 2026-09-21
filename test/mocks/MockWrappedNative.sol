// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";

/**
 * @notice WFUSE, as far as a deposit cares: wrap at par, unwrap at par.
 *
 * Par is not an assumption here — the deployed WFUSE holds exactly its own
 * total supply in native FUSE, so one WFUSE is one FUSE and a zap can treat
 * the two as the same amount.
 */
contract MockWrappedNative is ERC20 {
    constructor() ERC20("Wrapped FUSE", "WFUSE", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
