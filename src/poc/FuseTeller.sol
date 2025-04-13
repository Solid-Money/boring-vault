// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

contract FuseTeller {
    event Withdraw(address indexed caller, uint256 shares);

    constructor() {}

    function withdraw(uint256 shares) external {
        require(shares > 0, "Shares must be greater than 0");

        // Emit withdraw event
        emit Withdraw(msg.sender, shares);
    }
}
