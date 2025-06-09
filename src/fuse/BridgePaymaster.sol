// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {UUPSUpgradeable} from "@oz/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@oz/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@oz/access/OwnableUpgradeable.sol";

contract BridgePaymaster is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /**
     * @notice Whether or not to sponsor transactions to contracts.
     */
    mapping(address => bool) public isSponsored;

    error NotSponsored();
    error CallFailed();

    modifier onlySponsored(address _target) {
        if (!isSponsored[_target]) revert NotSponsored();
        _;
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
    }

    function setSponsored(
        address _target,
        bool _isSponsored
    ) external onlyOwner {
        isSponsored[_target] = _isSponsored;
    }

    function callWithValue(
        address target,
        bytes calldata data,
        uint256 value
    ) external onlySponsored(target) returns (bytes memory) {
        (bool success, bytes memory ret) = target.call{value: value}(data);
        if (!success) revert CallFailed();
        return ret;
    }

    function rescueNative(address to) external onlyOwner {
        payable(to).transfer(address(this).balance);
    }

    receive() external payable {}

    fallback() external payable {}

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
