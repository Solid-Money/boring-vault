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
import {ISupraSValueFeed} from "./ISupraSValueFeed.sol";

contract FastWithdrawManager is Auth, IPausable, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using AddressToBytes32Lib for address;
    using AddressToBytes32Lib for bytes32;

    // ========================================= CONSTANTS =========================================
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice Used to pause withdraw calls to `FastWithdrawManager`.
     */
    bool public isPaused;

    /**
     * @notice The SupraSValueFeed this FastWithdrawManager works with.
     */
    ISupraSValueFeed public supraSValueFeed;

    /**
     * @notice The index of the SupraSValueFeed for the fee token.
     */
    uint32 public supraSValueFeeTokenFeedIndex;

    // ========================================= PRIVATE =========================================

    //============================== ERRORS ===============================

    error FastWithdrawManager__Paused();
    error UnauthorizedEid();
    error UnauthorizedOFT();
    error InsufficientBalanceForSwap();
    error NativeTransferFailed();
    error ZeroAmount();
    error OFTSendFailed();
    error ERC20TransferFailed();
    error InsufficientAmountOut();
    error ZeroSValueFeed();

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
    event DstEidAllowed(uint32 indexed eid, bool isAllowed);
    event OFTAllowed(address indexed oft, bool isAllowed);
    event SwapPremiumSet(address indexed token, uint16 premium);
    event SupraSValueFeedUpdated(address indexed newSValueFeed);
    event SupraSValueFeeTokenFeedIndexUpdated(
        uint32 indexed newSupraSValueFeeTokenFeedIndex
    );

    //============================== IMMUTABLES ===============================

    /**
     * @notice The BoringVault this FastWithdrawManager works with.
     */
    BoringVault public immutable vault;

    /**
     * @notice One share of the BoringVault.
     */
    uint256 internal immutable ONE_SHARE;

    /**
     * @notice The AccountantWithRateProviders this FastWithdrawManager works with.
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
        address _supraSValueFeed,
        uint32 _supraSValueFeeTokenFeedIndex
    ) Auth(_owner, Authority(address(0))) {
        require(_owner != address(0), "Zero owner");
        require(_vault != address(0), "Zero vault");
        require(_accountant != address(0), "Zero accountant");
        vault = BoringVault(payable(_vault));
        accountant = AccountantWithRateProviders(_accountant);
        ONE_SHARE = 10 ** vault.decimals();
        supraSValueFeed = ISupraSValueFeed(_supraSValueFeed);
        supraSValueFeeTokenFeedIndex = _supraSValueFeeTokenFeedIndex;
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
        if (isPaused) revert FastWithdrawManager__Paused();
        _;
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
     * @notice update the SupraSValueFeed
     * @param _newSValueFeed the new SupraSValueFeed address
     */
    function updateSupraSValueFeed(
        address _newSValueFeed
    ) external requiresAuth {
        require(_newSValueFeed != address(0), "Zero SValueFeed");
        supraSValueFeed = ISupraSValueFeed(_newSValueFeed);
        emit SupraSValueFeedUpdated(_newSValueFeed);
    }

    function updateSupraSValueFeeTokenFeedIndex(
        uint32 _supraSValueFeeTokenFeedIndex
    ) external requiresAuth {
        supraSValueFeeTokenFeedIndex = _supraSValueFeeTokenFeedIndex;
        emit SupraSValueFeeTokenFeedIndexUpdated(_supraSValueFeeTokenFeedIndex);
    }

    /**
     * @notice get the SValue for the fee token
     * @return The SValue for the fee token
     */
    function getFeeTokenSValue()
        public
        view
        returns (ISupraSValueFeed.priceFeed memory)
    {
        ISupraSValueFeed.priceFeed memory sValue = supraSValueFeed.getSvalue(
            supraSValueFeeTokenFeedIndex
        );
        return sValue;
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
     * @return amountOut amount of tokens received
     * @return amountOutBeforePremium amount of tokens received before premium
     * @return feeAmount amount of native tokens paid for fee
     *
     * @dev MessagingReceipt: LayerZero msg receipt
     *  - guid: The unique identifier for the sent message.
     *  - nonce: The nonce of the sent message.
     *  - fee: The LayerZero fee incurred for the message.
     */
    function swapAndWithdrawUsingStargate(
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
        returns (
            bytes memory data,
            uint256 amountOut,
            uint256 amountOutBeforePremium,
            uint256 feeAmount
        )
    {
        _validateDstEid(_sendParam.dstEid);
        _validateOFT(_oft);
        ERC20(vault).safeTransferFrom(_from, address(this), _amountIn);
        address tokenOut = IOFT(_oft).token();
        (amountOut, feeAmount, amountOutBeforePremium) = _calculateSwap(
            tokenOut,
            _fee,
            _amountIn
        );
        if (amountOut < _sendParam.minAmountLD) revert InsufficientAmountOut();
        if (ERC20(tokenOut).balanceOf(address(this)) < amountOut) {
            revert InsufficientBalanceForSwap();
        }
        ERC20(tokenOut).safeApprove(_oft, amountOut);
        SendParam memory m = SendParam(
            _sendParam.dstEid,
            _sendParam.to,
            amountOut,
            _sendParam.minAmountLD,
            _sendParam.extraOptions,
            _sendParam.composeMsg,
            _sendParam.oftCmd
        );
        data = _withdrawUsingStargate(_oft, m, _fee, _refundAddress);
        emit Swap(tokenOut, _amountIn, amountOut);
        emit Deposit(_sendParam.to, tokenOut, _sendParam.dstEid, amountOut);
        return (data, amountOut, amountOutBeforePremium, feeAmount);
    }

    /**
     * @notice swaps and withdraws tokens from contract
     * @param _oft address of the OFT contract
     * @param _from address of sender wallet
     * @param _amountIn amount of tokens to swap
     * @param _to address to send tokens to
     * @return amountOut amount of tokens received
     * @return feeAmount amount of native tokens paid for fee
     * @return amountOutBeforePremium amount of tokens received before premium
     */
    function swapAndWithdraw(
        address _oft,
        address _from,
        uint256 _amountIn,
        address _to
    )
        external
        whenNotPaused
        nonReentrant
        returns (
            uint256 amountOut,
            uint256 feeAmount,
            uint256 amountOutBeforePremium
        )
    {
        _validateOFT(_oft);
        ERC20(vault).safeTransferFrom(_from, address(this), _amountIn);
        address tokenOut = IOFT(_oft).token();
        (amountOut, feeAmount, amountOutBeforePremium) = _calculateSwap(
            tokenOut,
            0,
            _amountIn
        );
        if (ERC20(tokenOut).balanceOf(address(this)) < amountOut) {
            revert InsufficientBalanceForSwap();
        }
        ERC20(tokenOut).safeTransfer(_to, amountOut);
        return (amountOut, feeAmount, amountOutBeforePremium);
    }

    /**
     * @notice calculates amount out for fast withdraw
     * @param _oft The address of stargate oft
     * @param _feeAmountNative amount of native tokens to pay for fee
     * @param _amountIn amount of tokens to swap
     */
    function previewFastWithdraw(
        address _oft,
        uint256 _feeAmountNative,
        uint256 _amountIn
    )
        external
        view
        returns (
            uint256 amountOut,
            uint256 feeAmount,
            uint256 amountOutBeforePremium
        )
    {
        address tokenOut = IOFT(_oft).token();
        (amountOut, feeAmount, amountOutBeforePremium) = _calculateSwap(
            tokenOut,
            _feeAmountNative,
            _amountIn
        );
        return (amountOut, feeAmount, amountOutBeforePremium);
    }

    // ========================================= INTERNAL FUNCTIONS =========================================

    function _withdrawUsingStargate(
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
        address _tokenOut,
        uint256 feeAmountNative,
        uint256 depositAmount
    )
        internal
        view
        returns (
            uint256 amountOut,
            uint256 feeAmount,
            uint256 amountOutBeforePremium
        )
    {
        if (depositAmount == 0) revert ZeroAmount();
        amountOut = depositAmount.mulDivDown(
            accountant.getRateInQuote(ERC20(_tokenOut)),
            ONE_SHARE
        );
        amountOutBeforePremium = amountOut;
        uint16 _swapPremium = swapPremium[_tokenOut];
        amountOut = _swapPremium > 0
            ? amountOut.mulDivDown(1e4 - _swapPremium, 1e4)
            : amountOut;
        ISupraSValueFeed.priceFeed memory sValue = getFeeTokenSValue();

        // Calculate fee in terms of value (e.g. USD) with 18 decimals
        // We assume feeAmountNative is 18 decimals (ETH/Native)
        // sValue.price is scaled by 10**sValue.decimals
        // Result feeAmount should be in 18 decimals first
        feeAmount = feeAmountNative.mulDivDown(sValue.price, 10 ** sValue.decimals);

        // Convert feeAmount from 18 decimals to _tokenOut decimals
        uint8 tokenDecimals = ERC20(_tokenOut).decimals();
        if (tokenDecimals < 18) {
            feeAmount = feeAmount / (10 ** (18 - tokenDecimals));
        } else if (tokenDecimals > 18) {
            feeAmount = feeAmount * (10 ** (tokenDecimals - 18));
        }

        if (feeAmount > amountOut) revert InsufficientAmountOut();
        amountOut = amountOut - feeAmount;
        return (amountOut, feeAmount, amountOutBeforePremium);
    }

    receive() external payable {}
}
