// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.21;

interface IWalletFactory {
    function deploy(uint _salt) external payable returns (address);

    function getBytecode() external view returns (bytes memory);

    function getAddress(
        uint256 _salt,
        address _manager
    ) external view returns (address);
}
