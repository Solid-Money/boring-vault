// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.21;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISimpleWallet} from "./interfaces/ISimpleWallet.sol";

contract SimpleWallet is ISimpleWallet {
    using SafeERC20 for IERC20;
    address public manager;
    event NativeTokensReceived(address indexed from, uint256 amount);

    constructor(address _manager) {
        manager = _manager;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "SimpleWallet: FORBIDDEN");
        _;
    }

    function transfer(
        address token,
        address to,
        uint256 amount
    ) public onlyManager {
        IERC20(token).safeTransfer(to, amount);
    }

    function transferNative(address to, uint256 amount) public onlyManager {
        (bool success, ) = to.call{value: amount, gas: 30000}("");
        require(success, "SimpleWallet: TRANSFER_FAILED");
    }

    function approve(address token, address spender, uint256 amount) public onlyManager {
        bool success = IERC20(token).approve(spender, amount);
        require(success, "SimpleWallet: APPROVE_FAILED");
    }

    receive() external payable {}

    fallback() external payable {}
}
