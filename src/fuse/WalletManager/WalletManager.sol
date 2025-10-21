// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.21;

import {UUPSUpgradeable} from "@oz/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@oz/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@oz/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@oz/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWalletFactory} from "./interfaces/IWalletFactory.sol";
import {ISimpleWallet} from "./interfaces/ISimpleWallet.sol";

contract WalletManager is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    address public operator;
    address public walletFactory;

    event WalletDeployed(address wallet, address indexed operator);
    event TokensBridged(
        address indexed from,
        address indexed to,
        address token,
        uint256 amountLD
    );
    event LogError(string message);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyOperator() {
        require(
            msg.sender == operator || msg.sender == owner(),
            "WalletManager: FORBIDDEN"
        );
        _;
    }

    function initialize(
        address initialOwner,
        address _operator
    ) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        operator = _operator;
    }

    function setOperator(address _operator) public onlyOwner {
        operator = _operator;
    }

    function setWalletFactory(address _walletFactory) public onlyOwner {
        walletFactory = _walletFactory;
    }

    function deployWallet(uint256 _salt) public payable onlyOperator {
        require(walletFactory != address(0), "WalletManager: ZERO_ADDRESS");
        address wallet = IWalletFactory(walletFactory).deploy(_salt);
        emit WalletDeployed(wallet, msg.sender);
    }

    function getAddress(uint256 _salt) public view returns (address) {
        require(walletFactory != address(0), "WalletManager: ZERO_ADDRESS");
        return IWalletFactory(walletFactory).getAddress(_salt, address(this));
    }

    function transferTokens(
        address from,
        address token,
        address to,
        uint256 amount
    ) public onlyOperator {
        ISimpleWallet(from).transfer(token, to, amount);
    }

    function transferTokens(
        address token,
        address to,
        uint256 amount
    ) public onlyOperator {
        IERC20(token).safeTransfer(to, amount);
    }

    function transferNative(
        address from,
        address to,
        uint256 amount
    ) public onlyOperator {
        ISimpleWallet(from).transferNative(to, amount);
    }

    function transferNative(address to, uint256 amount) public onlyOperator {
        payable(to).transfer(amount);
    }

    function approve(
        address from,
        address token,
        address to,
        uint256 amount
    ) public onlyOperator {
        ISimpleWallet(from).approve(token, to, amount);
    }

    receive() external payable {}

    fallback() external payable {}

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
