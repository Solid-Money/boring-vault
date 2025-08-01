// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {UUPSUpgradeable} from "@oz/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@oz/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@oz/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@oz/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BridgePaymaster is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    /**
     * @notice Whether or not to sponsor transactions to contracts.
     */
    mapping(address => mapping(bytes4 => bool)) public isSponsored;

    event SponsorUpdated(
        address indexed target,
        bytes4 indexed functionSig,
        bool isSponsored
    );

    error NotSponsored();
    error SignatureMistatch();
    error CallFailed();
    error NativeTransferFailed();
    error ERC20TransferFailed();
    error InsufficientBalance();
    error ERC20ApproveFailed();

    modifier onlySponsored(address _target, bytes4 _functionSig,bytes calldata data) {
        if(bytes4(data[0:4]) != _functionSig) revert SignatureMistatch();
        if (!isSponsored[_target][_functionSig]) revert NotSponsored();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    function setSponsored(
        address _target,
        bytes4 _functionSig,
        bool _isSponsored
    ) external onlyOwner {
        isSponsored[_target][_functionSig] = _isSponsored;
        emit SponsorUpdated(_target, _functionSig, _isSponsored);
    }

    function callWithValue(
        address target,
        bytes4 functionSig,
        bytes calldata data,
        uint256 value
    )
        external
        nonReentrant
        onlySponsored(target, functionSig,data)
        returns (bytes memory)
    {
        if (value > address(this).balance) revert InsufficientBalance();
        (bool success, bytes memory ret) = target.call{value: value}(data);
        if (!success) revert CallFailed();
        return ret;
    }

    function rescueNative(address to) external onlyOwner {
        (bool success, ) = to.call{value: address(this).balance}("");
        if (!success) revert NativeTransferFailed();
    }

    function rescueTokens(address token, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    function approveERC20(
        address token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        bool success = IERC20(token).approve(spender, amount);
        if (!success) revert ERC20ApproveFailed();
    }

    receive() external payable {}

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
