// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.21;

import {SimpleWallet} from "./SimpleWallet.sol";
import {IWalletFactory} from "./interfaces/IWalletFactory.sol";

contract WalletFactory is IWalletFactory {
    address public manager;

    constructor(address _manager) {
        manager = _manager;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "WalletDeployer: FORBIDDEN");
        _;
    }

    // Returns the address of the newly deployed contract
    function deploy(uint _salt) public payable onlyManager returns (address) {
        // This syntax is a newer way to invoke create2 without assembly, you just need to pass salt
        // https://docs.soliditylang.org/en/latest/control-structures.html#salted-contract-creations-create2
        return address(new SimpleWallet{salt: bytes32(_salt)}(msg.sender));
    }

    // 1. Get bytecode of contract to be deployed
    function getBytecode() public view returns (bytes memory) {
        bytes memory bytecode = type(SimpleWallet).creationCode;
        return abi.encodePacked(bytecode, abi.encode(msg.sender));
    }

    /** 2. Compute the address of the contract to be deployed
        params:
            _salt: random unsigned number used to precompute an address
    */
    function getAddress(
        uint256 _salt,
        address _manager
    ) public view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(SimpleWallet).creationCode,
            abi.encode(_manager)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _salt,
                keccak256(bytecode)
            )
        );
        return address(uint160(uint256(hash)));
    }
}
