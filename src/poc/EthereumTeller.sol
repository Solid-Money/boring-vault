// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract EthereumTeller {
    event Deposit(address indexed caller, uint256 amount);

    address public immutable weth;
    BoringVault public immutable vault;

    constructor(address _weth, BoringVault _vault) {
        require(_weth != address(0), "Invalid WETH address");
        require(address(_vault) != address(0), "Invalid vault address");
        weth = _weth;
        vault = _vault;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer WETH from user to this contract
        bool success = IERC20(weth).transferFrom(
            msg.sender,
            address(vault),
            amount
        );
        require(success, "Transfer failed");

        // Emit deposit event
        emit Deposit(msg.sender, amount);
    }
    
    // New function to accept ETH directly
    function depositETH() public payable {
        require(msg.value > 0, "Amount must be greater than 0");
        
        // Convert ETH to WETH
        IWETH(weth).deposit{value: msg.value}();
        
        // Transfer WETH to vault
        bool success = IERC20(weth).transfer(address(vault), msg.value);
        require(success, "Transfer failed");
        
        // Emit deposit event
        emit Deposit(msg.sender, msg.value);
    }
    
    // Allow contract to receive ETH
    receive() external payable {
        depositETH();
    }
}
