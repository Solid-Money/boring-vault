// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {BoringVault} from "src/base/BoringVault.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {IPausable} from "src/interfaces/IPausable.sol";
import {AccountantWithRateProviders} from "src/base/Roles/AccountantWithRateProviders.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IOFT, SendParam, MessagingFee, OFTReceipt} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";
import {MessagingReceipt} from "@oapp-auth/OAppAuth.sol";
import {AddressToBytes32Lib} from "src/helper/AddressToBytes32Lib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CardDepositManager is Auth, IPausable, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using AddressToBytes32Lib for address;
    using AddressToBytes32Lib for bytes32;

    // ========================================= CONSTANTS =========================================
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice Used to pause deposit calls to `CardManager`.
     */
    bool public isPaused;

    /**
     * @notice Used to enable whitelist for deposit calls to `CardManager`.
     */
    bool public isWhitelistEnabled;
    // ========================================= PRIVATE =========================================

    /**
     * @notice Authorized card addresses
     */
    EnumerableSet.Bytes32Set private authorizedCards;

    //============================== ERRORS ===============================

    error CardManager__Paused();
    error UnauthorizedCard();
    error UnauthorizedEid();
    error UnauthorizedOFT();
    error InsufficientBalanceForSwap();
    error NativeTransferFailed();
    error ZeroAmount();
    error OFTSendFailed();
    error ERC20TransferFailed();
    error InsufficientAmountOut();

    //============================== EVENTS ===============================
    event Paused();
    event Unpaused();
    event Deposit(
        bytes32 indexed to,
        address indexed token,
        uint32 dstEid,
        uint256 amount
    );
    event Swap(address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event CardAuthorized(address indexed card);
    event DstEidAllowed(uint32 indexed eid, bool isAllowed);
    event OFTAllowed(address indexed oft, bool isAllowed);
    event SwapPremiumSet(address indexed token, uint16 premium);
    event WhitelistToggled(bool isWhitelistEnabled);
    event CardsDeauthorized(address indexed card);
    
    //============================== IMMUTABLES ===============================

    /**
     * @notice The BoringVault this CardManager works with.
     */
    BoringVault public immutable vault;

    /**
     * @notice One share of the BoringVault.
     */
    uint256 internal immutable ONE_SHARE;

    /**
     * @notice The AccountantWithRateProviders this CardManager works with.
     */
    AccountantWithRateProviders public immutable accountant;

    //============================== MAPPINGS ===============================
    mapping(uint32 => bool) allowedDstEid;
    mapping(address => bool) allowedOFTs;
    mapping(address => uint16) swapPremium;

    constructor(
        address _owner,
        address _vault,
        address _accountant,
        bool _isWhitelistEnabled
    ) Auth(_owner, Authority(address(0))) {
        require(_owner != address(0), "Zero owner");
        require(_vault != address(0), "Zero vault");
        require(_accountant != address(0), "Zero accountant");
        vault = BoringVault(payable(_vault));
        accountant = AccountantWithRateProviders(_accountant);
        ONE_SHARE = 10 ** vault.decimals();
        isWhitelistEnabled = _isWhitelistEnabled;
    }

    /**
     * @notice Pause this contract, which prevents future calls to `deposit`.
     * @dev Callable by MULTISIG_ROLE.
     */
    function pause() external requiresAuth {
        isPaused = true;
        emit Paused();
    }

    /**
     * @notice Unpause this contract, which allows future calls to `deposit`.
     * @dev Callable by MULTISIG_ROLE.
     */
    function unpause() external requiresAuth {
        isPaused = false;
        emit Unpaused();
    }

    modifier whenNotPaused() {
        if (isPaused) revert CardManager__Paused();
        _;
    }

    /**
     * @notice set whitelist enabled
     * @param _isWhitelistEnabled the status of the whitelist
     */
    function setWhitelistEnabled(
        bool _isWhitelistEnabled
    ) external requiresAuth {
        isWhitelistEnabled = _isWhitelistEnabled;
        emit WhitelistToggled(_isWhitelistEnabled);
    }

    /**
     * @notice Use this to check if a card address is authorized for deposits
     * @param cardAddress The address of the card
     * @return The authorization status of the card
     */
    function isAuthorizedCardAddress(
        address cardAddress
    ) public view returns (bool) {
        return authorizedCards.contains(cardAddress.toBytes32());
    }

    function _isAuthorizedCardAddress(
        bytes32 cardAddress
    ) internal view returns (bool) {
        return authorizedCards.contains(cardAddress);
    }

    /**
     * @notice validates the card is authorized
     */
    function _validateIsAuthorizedCard(bytes32 card) internal view {
        if (!isWhitelistEnabled) return;
        if (!_isAuthorizedCardAddress(card)) {
            revert UnauthorizedCard();
        }
    }

    /**
     * @notice authorizeCards
     */
    function authorizeCards(address[] memory cards) external requiresAuth {
        for (uint256 i = 0; i < cards.length; i++) {
            authorizedCards.add(cards[i].toBytes32());
            emit CardAuthorized(cards[i]);
        }
    }

    /**
     * @notice deauthorizeCards
     */
    function deauthorizeCards(address[] memory cards) external requiresAuth {
        for (uint256 i = 0; i < cards.length; i++) {
            authorizedCards.remove(cards[i].toBytes32());
            emit CardsDeauthorized(cards[i]);
        }
    }

    /**
     * @notice allowDstEid
     */
    function setAllowDstEid(uint32 eid, bool isAllowed) external requiresAuth {
        allowedDstEid[eid] = isAllowed;
        emit DstEidAllowed(eid, isAllowed);
    }

    /**
     * @notice Use this to check if a dst eid is allowed
     * @param eid The eid of the destination chain
     * @return The status of the eid
     */
    function isAllowedEid(uint32 eid) public view returns (bool) {
        return allowedDstEid[eid];
    }

    /**
     * @notice validates destination Eid is allowed
     */
    function _validateDstEid(uint32 eid) internal view {
        if (!isAllowedEid(eid)) {
            revert UnauthorizedEid();
        }
    }

    /**
     * @notice allowOFT
     */
    function setAllowOFT(address oft, bool isAllowed) external requiresAuth {
        allowedOFTs[oft] = isAllowed;
        emit OFTAllowed(oft, isAllowed);
    }

    /**
     * @notice Use this to check if a oft address is allowed
     * @param oft The address of stargate oft
     * @return The status of the oft
     */
    function isAllowedOFT(address oft) public view returns (bool) {
        return allowedOFTs[oft];
    }

    /**
     * @notice validates destination Eid is allowed
     */
    function _validateOFT(address oft) internal view {
        if (!isAllowedOFT(oft)) {
            revert UnauthorizedOFT();
        }
    }

    /**
     * @notice set swap premium for a token
     * @param token The address of stargate oft
     * @param premium the swap premium
     */
    function setSwapPremium(
        address token,
        uint16 premium
    ) external requiresAuth {
        require(premium < BPS_DENOMINATOR);
        swapPremium[token] = premium;
        emit SwapPremiumSet(token, premium);
    }

    /**
     * @notice withdraw ERC20 from contract
     * @param token The address of stargate oft
     * @param to address to send tokens to
     */
    function withdrawToken(address token, address to) external requiresAuth {
        require(token != address(0), "Zero Token");
        require(to != address(0), "Zero Address");
        uint256 balance = ERC20(token).balanceOf(address(this));
        ERC20(token).safeTransfer(to, balance);
    }

    /**
     * @notice withdraw native from contract
     * @param to address to send tokens to
     */
    function withdrawNative(address to) external requiresAuth {
        require(to != address(0), "Zero Address");
        (bool success, ) = to.call{value: address(this).balance}("");
        if (!success) revert NativeTransferFailed();
    }

    /**
     * @notice Executes the send() operation on Stargate OFT.
     * @param oft address of the OFT contract
     * @param from address of sender wallet
     * @param _sendParam The parameters for the send operation.
     * @param _fee The fee information supplied by the caller.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     * @param _refundAddress The address to receive any excess funds from fees etc. on the src.
     * @return data The LayerZero messaging receipt from the send() operation.
     *
     * @dev MessagingReceipt: LayerZero msg receipt
     *  - guid: The unique identifier for the sent message.
     *  - nonce: The nonce of the sent message.
     *  - fee: The LayerZero fee incurred for the message.
     */
    function depositUsingStargate(
        address oft,
        address from,
        SendParam calldata _sendParam,
        uint256 _fee,
        address _refundAddress
    ) external payable whenNotPaused nonReentrant returns (bytes memory data) {
        _validateIsAuthorizedCard(_sendParam.to);
        _validateDstEid(_sendParam.dstEid);
        _validateOFT(oft);
        address token = IOFT(oft).token();
        ERC20(token).safeTransferFrom(from, address(this), _sendParam.amountLD);
        ERC20(token).approve(oft, _sendParam.amountLD);
        data = _depositUsingStargate(oft, _sendParam, _fee, _refundAddress);
        emit Deposit(
            _sendParam.to,
            token,
            _sendParam.dstEid,
            _sendParam.amountLD
        );
        return data;
    }

    /**
     * @notice Executes the send() operation on Stargate OFT.
     * @param _oft address of the OFT contract
     * @param _from address of sender wallet
     * @param _sendParam The parameters for the send operation.
     * @param _fee The fee information supplied by the caller.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     * @param _refundAddress The address to receive any excess funds from fees etc. on the src.
     * @return data The LayerZero messaging receipt from the send() operation.
     * @return amtOut The OFT receipt information.
     *
     * @dev MessagingReceipt: LayerZero msg receipt
     *  - guid: The unique identifier for the sent message.
     *  - nonce: The nonce of the sent message.
     *  - fee: The LayerZero fee incurred for the message.
     */
    function swapAndDepositUsingStargate(
        address _oft,
        address _from,
        uint256 _amountIn,
        SendParam calldata _sendParam,
        uint256 _fee,
        address _refundAddress
    )
        external
        payable
        whenNotPaused
        nonReentrant
        returns (bytes memory data, uint256 amtOut)
    {
        _validateIsAuthorizedCard(_sendParam.to);
        _validateDstEid(_sendParam.dstEid);
        _validateOFT(_oft);
        ERC20(vault).safeTransferFrom(_from, address(this), _amountIn);
        address tokenOut = IOFT(_oft).token();
        uint256 amountOut = _calculateSwap(tokenOut, _amountIn);
        if (amountOut < _sendParam.minAmountLD) revert InsufficientAmountOut();
        if (ERC20(tokenOut).balanceOf(address(this)) < amountOut) {
            revert InsufficientBalanceForSwap();
        }
        ERC20(tokenOut).approve(_oft, amountOut);
        SendParam memory m = SendParam(
            _sendParam.dstEid,
            _sendParam.to,
            amountOut,
            _sendParam.minAmountLD,
            _sendParam.extraOptions,
            _sendParam.composeMsg,
            _sendParam.oftCmd
        );
        data = _depositUsingStargate(_oft, m, _fee, _refundAddress);
        emit Swap(tokenOut, _amountIn, amountOut);
        emit Deposit(_sendParam.to, tokenOut, _sendParam.dstEid, amountOut);
        return (data, amountOut);
    }

    /**
     * @notice calculates amount out for swap
     * @param _oft The address of stargate oft
     * @param _amountIn amount of tokens to swap
     */
    function previewSwap(
        address _oft,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        address tokenOut = IOFT(_oft).token();
        amountOut = _calculateSwap(tokenOut, _amountIn);
    }

    // ========================================= INTERNAL FUNCTIONS =========================================

    function _depositUsingStargate(
        address oft,
        SendParam memory _sendParam,
        uint256 _fee,
        address _refundAddress
    ) internal returns (bytes memory) {
        MessagingFee memory fee = MessagingFee(_fee, 0);
        (bool success, bytes memory data) = address(oft).call{value: msg.value}(
            abi.encodeWithSelector(
                IOFT.send.selector,
                _sendParam,
                fee,
                _refundAddress
            )
        );
        if (!success) revert OFTSendFailed();
        return data;
    }

    /**
     * @notice Implements swap amount for Boring Vault Share
     */
    function _calculateSwap(
        address tokenOut,
        uint256 depositAmount
    ) internal view returns (uint256 amountOut) {
        if (depositAmount == 0) revert ZeroAmount();
        amountOut = depositAmount.mulDivDown(
            accountant.getRateInQuote(ERC20(tokenOut)),
            ONE_SHARE
        );
        uint16 _swapPremium = swapPremium[tokenOut];
        amountOut = _swapPremium > 0
            ? amountOut.mulDivDown(1e4 - _swapPremium, 1e4)
            : amountOut;
    }

    receive() external payable {}
}
