// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.21;

interface ISimpleWallet {
    function transfer(address token, address to, uint256 amount) external;
    function transferNative(address to, uint256 amount) external;
    function approve(address token, address spender, uint256 amount) external;
}
