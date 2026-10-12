// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {UUPSUpgradeable} from "@oz/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@oz/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@oz/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@oz/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable} from "@oz/utils/cryptography/EIP712Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// One line: hardhat.config.js only rewrites remapped paths on lines that start with `import`.
import {IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";

interface IBridgeTeller {
    function vault() external view returns (address);

    function previewFee(uint96 shareAmount, address to, bytes calldata bridgeWildCard, address feeToken)
        external
        view
        returns (uint256 fee);

    function bridge(uint96 shareAmount, address to, bytes calldata bridgeWildCard, address feeToken, uint256 maxFee)
        external
        payable;

    function depositAndBridge(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata bridgeWildCard,
        address feeToken,
        uint256 maxFee
    ) external payable returns (uint256 sharesBridged);
}

interface ICardDepositManager {
    function isAllowedOFT(address oft) external view returns (bool);

    function depositUsingStargate(
        address oft,
        address from,
        SendParam calldata sendParam,
        uint256 fee,
        address refundAddress
    ) external payable returns (bytes memory data);

    function swapAndDepositUsingStargate(
        address oft,
        address from,
        uint256 amountIn,
        SendParam calldata sendParam,
        uint256 fee,
        address refundAddress
    ) external payable returns (bytes memory data, uint256 amountOut);
}

interface IFastWithdrawManager {
    function isAllowedOFT(address oft) external view returns (bool);

    function swapAndWithdrawUsingStargate(
        address oft,
        address from,
        uint256 amountIn,
        SendParam calldata sendParam,
        uint256 fee,
        address refundAddress
    )
        external
        payable
        returns (bytes memory data, uint256 amountOut, uint256 amountOutBeforePremium, uint256 feeAmount);
}

/**
 * @notice Pays the native bridge fee on behalf of users for a fixed set of vault operations.
 *
 * @dev This contract deliberately exposes NO generic call primitive. An earlier version had
 *      `callWithValue(target, functionSig, data, value)`, which let any caller pick the target,
 *      the calldata and - fatally - the amount of native to forward. On 2026-09-02 that was used
 *      to call `CardDepositManager.depositUsingStargate` with a caller-controlled `_refundAddress`
 *      and `value` equal to this contract's entire balance: Stargate charged the real ~75 FUSE
 *      fee and refunded the ~25,471 FUSE excess to the attacker. A per-call cap does not fix this,
 *      since the same script can simply be run once per cap.
 *
 *      Instead, every sponsored operation below:
 *        1. accepts only a target this contract's owner has registered under the matching kind,
 *        2. builds the calldata itself, so no caller-supplied bytes are ever forwarded,
 *        3. quotes the native fee on-chain and forwards exactly that - the caller never names an
 *           amount, so there is no excess to redirect,
 *        4. names this contract as the refund address, so any dust that is refunded anyway
 *           returns to the sponsor pool rather than to the caller,
 *        5. moves only assets pulled from `msg.sender`, so a caller can only ever bridge or
 *           deposit their own funds, and
 *        6. refuses LayerZero `extraOptions` and `composeMsg`. The fee in rule 3 is quoted for
 *           the caller's `SendParam`, so a native gas drop in its options would be quoted - and
 *           paid by this contract - too: a 1 USDC send to Arbitrum quotes ~36 FUSE bare and
 *           ~4,093 FUSE with a 0.01 ETH drop to an address of the caller's choosing.
 *
 *      `bridgeSend` is the one entrypoint that is not a subsidy: it fronts the native fee and
 *      takes the same value back from the amount, in the token being bridged, at a price the
 *      backend signs into an EIP-712 voucher. There is no usable FUSE price on-chain, so the
 *      voucher's `maxNativeFee` is what bounds the pricing - a fee above it reverts.
 */
contract BridgePaymaster is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    /**
     * @notice The kind of sponsored contract a target is registered as.
     * @dev A target is only reachable through the entrypoint matching its kind, so a card manager
     *      can never be driven through a teller entrypoint or vice versa.
     */
    enum TargetKind {
        NONE,
        TELLER,
        CARD_DEPOSIT_MANAGER,
        FAST_WITHDRAW_MANAGER,
        STARGATE_OFT
    }

    /**
     * @notice A backend-signed authorisation for one `bridgeSend`.
     * @dev Every field is covered by the signature, so a caller cannot lower `feeLD`, raise
     *      `amountLD` or `maxNativeFee`, or redirect the send without invalidating it. Amounts are
     *      in the OFT's local decimals on Fuse.
     * @param from The Safe allowed to spend this voucher; must be `msg.sender`.
     * @param oft The Stargate OFT on Fuse to bridge through.
     * @param dstEid The LayerZero endpoint id of the destination chain.
     * @param to The recipient on the destination chain.
     * @param amountLD Total pulled from `from`, the fee included.
     * @param feeLD The native fee's value in the bridged token, kept by `feeRecipient`.
     * @param maxNativeFee The native fee `feeLD` was priced at; a higher quote reverts.
     * @param minAmountLD Least the recipient may receive, after both fees.
     * @param nonce Unique per voucher; spent on use.
     * @param deadline Last timestamp the voucher can be used at.
     */
    struct SendVoucher {
        address from;
        address oft;
        uint32 dstEid;
        address to;
        uint256 amountLD;
        uint256 feeLD;
        uint256 maxNativeFee;
        uint256 minAmountLD;
        uint256 nonce;
        uint64 deadline;
    }

    bytes32 public constant SEND_VOUCHER_TYPEHASH = keccak256(
        "SendVoucher(address from,address oft,uint32 dstEid,address to,uint256 amountLD,uint256 feeLD,uint256 maxNativeFee,uint256 minAmountLD,uint256 nonce,uint64 deadline)"
    );

    /**
     * @dev Slot retained from the pre-2026-09 layout, where it gated the removed `callWithValue`.
     *      Kept so this implementation can be dropped onto the existing proxy without shifting
     *      storage; nothing reads it.
     * @custom:oz-renamed-from isSponsored
     */
    mapping(address => mapping(bytes4 => bool)) private __deprecated_isSponsored;

    /**
     * @notice Contracts this paymaster will sponsor calls to, and the entrypoint each is reachable
     *         through. Only the owner can register a target.
     */
    mapping(address => TargetKind) public targetKind;

    /**
     * @notice Smallest amount, denominated in the asset the target moves, that will be sponsored.
     * @dev Every sponsored call costs this contract a real bridge fee, so without a floor an
     *      attacker can burn the balance by bridging dust in a loop. Set this high enough that the
     *      fee is small relative to the amount moved.
     */
    mapping(address => uint256) public minSponsoredAmount;

    /**
     * @notice The key whose EIP-712 signature authorises each `bridgeSend`.
     */
    address public voucherSigner;

    /**
     * @notice Where `bridgeSend` sends the fee it takes in the bridged token.
     */
    address public feeRecipient;

    /**
     * @notice Voucher nonces already spent.
     */
    mapping(uint256 => bool) public usedNonce;

    /**
     * @notice Destination chains each `STARGATE_OFT` target may be bridged to.
     */
    mapping(address => mapping(uint32 => bool)) public allowedDstEid;

    /**
     * @notice Largest amount `bridgeSend` moves in one call, per OFT, in its local decimals.
     */
    mapping(address => uint256) public maxSponsoredAmount;

    /**
     * @notice Most native fee `bridgeSend` may front per UTC day.
     * @dev Each send repays its fee in tokens, so in normal operation this is never approached.
     *      It is the backstop for a leaked `voucherSigner` key, which could sign a zero `feeLD`.
     */
    uint256 public dailyFeeBudget;

    /**
     * @notice The day (`block.timestamp / 1 days`) that `feeSpentToday` counts.
     */
    uint256 public feeDay;

    /**
     * @notice Native fee fronted by `bridgeSend` so far on `feeDay`.
     */
    uint256 public feeSpentToday;

    /**
     * @notice Fee token sentinel the tellers use to mean "pay in native".
     */
    address internal constant NATIVE_FEE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event TargetUpdated(address indexed target, TargetKind kind, uint256 minSponsoredAmount);
    event FeeSponsored(address indexed target, address indexed caller, uint256 fee);
    event VoucherSignerUpdated(address indexed signer);
    event FeeRecipientUpdated(address indexed recipient);
    event RouteUpdated(address indexed oft, uint32 indexed dstEid, bool allowed);
    event MaxSponsoredAmountUpdated(address indexed target, uint256 maxSponsoredAmount);
    event DailyFeeBudgetUpdated(uint256 dailyFeeBudget);
    event BridgeSent(
        address indexed from,
        address indexed oft,
        uint256 indexed nonce,
        uint32 dstEid,
        address to,
        uint256 amountLD,
        uint256 feeLD,
        uint256 amountReceivedLD,
        bytes32 guid,
        uint256 nativeFee
    );

    error UnsupportedTarget();
    error AmountBelowMinimum();
    error NativeTransferFailed();
    error InsufficientBalance();
    error OFTNotAllowed();
    error OptionsNotAllowed();
    error ZeroAddress();
    error VoucherNotForCaller();
    error VoucherExpired();
    error VoucherUsed();
    error InvalidVoucherSignature();
    error RouteNotAllowed();
    error AmountAboveMaximum();
    error FeeExceedsAmount();
    error NativeFeeAboveVoucher();
    error DailyFeeBudgetExceeded();

    modifier onlyTarget(address target, TargetKind kind) {
        if (targetKind[target] != kind) revert UnsupportedTarget();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /**
     * @notice Sets up `bridgeSend` on a proxy already initialised at version 1.
     * @dev Run through `upgradeToAndCall` in the same Safe transaction as the upgrade. It is
     *      owner-only as well as a reinitializer: left open, anyone could call it between the
     *      upgrade and the Safe's next transaction and install their own voucher signer.
     */
    function initializeV2(address _voucherSigner, address _feeRecipient, uint256 _dailyFeeBudget)
        external
        reinitializer(2)
        onlyOwner
    {
        __EIP712_init("BridgePaymaster", "1");
        _setVoucherSigner(_voucherSigner);
        _setFeeRecipient(_feeRecipient);
        dailyFeeBudget = _dailyFeeBudget;
        emit DailyFeeBudgetUpdated(_dailyFeeBudget);
    }

    // ========================================= ADMIN =========================================

    /**
     * @notice Register (or with `TargetKind.NONE`, deregister) a contract this paymaster sponsors.
     * @param target The teller or manager to sponsor calls to.
     * @param kind Which entrypoint `target` becomes reachable through.
     * @param _minSponsoredAmount Smallest amount that entrypoint will sponsor, in the units of the
     *        asset that target moves.
     */
    function setTarget(address target, TargetKind kind, uint256 _minSponsoredAmount) external onlyOwner {
        targetKind[target] = kind;
        minSponsoredAmount[target] = _minSponsoredAmount;
        emit TargetUpdated(target, kind, _minSponsoredAmount);
    }

    /**
     * @notice Rotate the key that signs `bridgeSend` vouchers. Outstanding vouchers signed by the
     *         old key stop working at once.
     */
    function setVoucherSigner(address signer) external onlyOwner {
        _setVoucherSigner(signer);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        _setFeeRecipient(recipient);
    }

    /**
     * @notice Allow or disallow bridging `oft` to `dstEid` through `bridgeSend`.
     */
    function setRoute(address oft, uint32 dstEid, bool allowed) external onlyOwner {
        allowedDstEid[oft][dstEid] = allowed;
        emit RouteUpdated(oft, dstEid, allowed);
    }

    /**
     * @notice Set the largest amount `bridgeSend` moves per call through `target`.
     */
    function setMaxSponsoredAmount(address target, uint256 _maxSponsoredAmount) external onlyOwner {
        maxSponsoredAmount[target] = _maxSponsoredAmount;
        emit MaxSponsoredAmountUpdated(target, _maxSponsoredAmount);
    }

    function setDailyFeeBudget(uint256 _dailyFeeBudget) external onlyOwner {
        dailyFeeBudget = _dailyFeeBudget;
        emit DailyFeeBudgetUpdated(_dailyFeeBudget);
    }

    // ================================= SPONSORED OPERATIONS =================================

    /**
     * @notice Bridge vault shares owned by the caller to another chain, paying the LayerZero fee.
     * @dev Pulls `shareAmount` shares from the caller, so the caller must have approved this
     *      contract on the teller's vault. The teller burns them from this contract and mints to
     *      `to` on the destination chain.
     */
    function sponsorBridge(address teller, uint96 shareAmount, address to, bytes calldata bridgeWildCard)
        external
        nonReentrant
        onlyTarget(teller, TargetKind.TELLER)
        returns (uint256 fee)
    {
        if (shareAmount < minSponsoredAmount[teller]) revert AmountBelowMinimum();

        IERC20(IBridgeTeller(teller).vault()).safeTransferFrom(msg.sender, address(this), shareAmount);

        fee = IBridgeTeller(teller).previewFee(shareAmount, to, bridgeWildCard, NATIVE_FEE_TOKEN);
        if (fee > address(this).balance) revert InsufficientBalance();

        IBridgeTeller(teller).bridge{value: fee}(shareAmount, to, bridgeWildCard, NATIVE_FEE_TOKEN, fee);

        emit FeeSponsored(teller, msg.sender, fee);
    }

    /**
     * @notice Deposit the caller's asset into the vault and bridge the minted shares, paying the
     *         LayerZero fee.
     * @dev Pulls `depositAmount` from the caller, so the caller must have approved this contract
     *      on `depositAsset`. This contract in turn approves the vault, which is what pulls the
     *      asset in during `enter`.
     */
    function sponsorDepositAndBridge(
        address teller,
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata bridgeWildCard
    ) external nonReentrant onlyTarget(teller, TargetKind.TELLER) returns (uint256 fee) {
        if (depositAmount < minSponsoredAmount[teller]) revert AmountBelowMinimum();

        IERC20(depositAsset).safeTransferFrom(msg.sender, address(this), depositAmount);
        IERC20(depositAsset).forceApprove(IBridgeTeller(teller).vault(), depositAmount);

        // The bridged message is a fixed-size payload, so its fee does not depend on the share
        // amount - which is not known until the deposit lands. Quoting with 0 matches what the
        // teller will quote internally, and is passed as `maxFee` so any drift reverts.
        fee = IBridgeTeller(teller).previewFee(0, to, bridgeWildCard, NATIVE_FEE_TOKEN);
        if (fee > address(this).balance) revert InsufficientBalance();

        IBridgeTeller(teller).depositAndBridge{value: fee}(
            depositAsset, depositAmount, minimumMint, to, bridgeWildCard, NATIVE_FEE_TOKEN, fee
        );

        IERC20(depositAsset).forceApprove(IBridgeTeller(teller).vault(), 0);

        emit FeeSponsored(teller, msg.sender, fee);
    }

    /**
     * @notice Bridge the caller's tokens to their card via Stargate, paying the Stargate fee.
     * @dev The manager pulls the tokens from the caller, so the caller must have approved the
     *      manager - not this contract - on the deposit token.
     */
    function sponsorCardDeposit(address manager, address oft, SendParam calldata sendParam)
        external
        nonReentrant
        onlyTarget(manager, TargetKind.CARD_DEPOSIT_MANAGER)
        returns (uint256 fee)
    {
        if (sendParam.amountLD < minSponsoredAmount[manager]) revert AmountBelowMinimum();
        if (!ICardDepositManager(manager).isAllowedOFT(oft)) revert OFTNotAllowed();
        _requireNoOptions(sendParam);

        fee = IOFT(oft).quoteSend(sendParam, false).nativeFee;
        if (fee > address(this).balance) revert InsufficientBalance();

        ICardDepositManager(manager).depositUsingStargate{value: fee}(
            oft, msg.sender, sendParam, fee, address(this)
        );

        emit FeeSponsored(manager, msg.sender, fee);
    }

    /**
     * @notice Swap the caller's vault shares to the card's deposit token and bridge them via
     *         Stargate, paying the Stargate fee.
     * @dev The manager pulls the shares from the caller, so the caller must have approved the
     *      manager - not this contract - on the vault.
     */
    function sponsorCardSwapAndDeposit(
        address manager,
        address oft,
        uint256 amountIn,
        SendParam calldata sendParam
    ) external nonReentrant onlyTarget(manager, TargetKind.CARD_DEPOSIT_MANAGER) returns (uint256 fee) {
        if (amountIn < minSponsoredAmount[manager]) revert AmountBelowMinimum();
        if (!ICardDepositManager(manager).isAllowedOFT(oft)) revert OFTNotAllowed();
        _requireNoOptions(sendParam);

        fee = IOFT(oft).quoteSend(sendParam, false).nativeFee;
        if (fee > address(this).balance) revert InsufficientBalance();

        ICardDepositManager(manager).swapAndDepositUsingStargate{value: fee}(
            oft, msg.sender, amountIn, sendParam, fee, address(this)
        );

        emit FeeSponsored(manager, msg.sender, fee);
    }

    /**
     * @notice Swap the caller's vault shares out and bridge them via Stargate, paying the Stargate
     *         fee.
     * @dev The manager pulls the shares from the caller, so the caller must have approved the
     *      manager - not this contract - on the vault. The manager charges the fee back to the
     *      caller out of their output, bounded by `sendParam.minAmountLD`.
     */
    function sponsorFastWithdraw(address manager, address oft, uint256 amountIn, SendParam calldata sendParam)
        external
        nonReentrant
        onlyTarget(manager, TargetKind.FAST_WITHDRAW_MANAGER)
        returns (uint256 fee)
    {
        if (amountIn < minSponsoredAmount[manager]) revert AmountBelowMinimum();
        if (!IFastWithdrawManager(manager).isAllowedOFT(oft)) revert OFTNotAllowed();
        _requireNoOptions(sendParam);

        fee = IOFT(oft).quoteSend(sendParam, false).nativeFee;
        if (fee > address(this).balance) revert InsufficientBalance();

        IFastWithdrawManager(manager).swapAndWithdrawUsingStargate{value: fee}(
            oft, msg.sender, amountIn, sendParam, fee, address(this)
        );

        emit FeeSponsored(manager, msg.sender, fee);
    }

    /**
     * @notice Bridge the caller's Stargate USDC.e or USDT from Fuse to any address on an allowed
     *         chain, fronting the LayerZero fee and taking it back in the bridged token.
     * @dev The caller must have approved this contract for `v.amountLD` on the OFT's token. Of
     *      that, `v.feeLD` goes to `feeRecipient` and the rest is sent in taxi mode with no
     *      options and no compose message, so the native fee quoted is the bare message fee.
     */
    function bridgeSend(SendVoucher calldata v, bytes calldata signature)
        external
        nonReentrant
        onlyTarget(v.oft, TargetKind.STARGATE_OFT)
        returns (uint256 nativeFee, bytes32 guid)
    {
        _useVoucher(v, signature);

        if (!allowedDstEid[v.oft][v.dstEid]) revert RouteNotAllowed();
        if (v.to == address(0)) revert ZeroAddress();
        if (v.amountLD < minSponsoredAmount[v.oft]) revert AmountBelowMinimum();
        if (v.amountLD > maxSponsoredAmount[v.oft]) revert AmountAboveMaximum();
        if (v.feeLD >= v.amountLD) revert FeeExceedsAmount();

        IERC20 token = IERC20(IOFT(v.oft).token());
        token.safeTransferFrom(msg.sender, address(this), v.amountLD);
        if (v.feeLD != 0) token.safeTransfer(feeRecipient, v.feeLD);

        uint256 amountReceivedLD;
        (nativeFee, guid, amountReceivedLD) = _send(v, token);

        emit BridgeSent(
            msg.sender, v.oft, v.nonce, v.dstEid, v.to, v.amountLD, v.feeLD, amountReceivedLD, guid, nativeFee
        );
    }

    /**
     * @notice The EIP-712 digest a voucher signer signs for `v`.
     * @dev Exposed so the backend can check its encoding against the contract's.
     */
    function hashVoucher(SendVoucher calldata v) external view returns (bytes32) {
        return _hashTypedDataV4(_voucherStructHash(v));
    }

    // ======================================== INTERNAL ========================================

    function _requireNoOptions(SendParam calldata sendParam) internal pure {
        if (sendParam.extraOptions.length != 0 || sendParam.composeMsg.length != 0) revert OptionsNotAllowed();
    }

    function _useVoucher(SendVoucher calldata v, bytes calldata signature) internal {
        if (v.from != msg.sender) revert VoucherNotForCaller();
        if (block.timestamp > v.deadline) revert VoucherExpired();
        if (usedNonce[v.nonce]) revert VoucherUsed();
        if (ECDSA.recover(_hashTypedDataV4(_voucherStructHash(v)), signature) != voucherSigner) {
            revert InvalidVoucherSignature();
        }
        usedNonce[v.nonce] = true;
    }

    function _voucherStructHash(SendVoucher calldata v) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SEND_VOUCHER_TYPEHASH,
                v.from,
                v.oft,
                v.dstEid,
                v.to,
                v.amountLD,
                v.feeLD,
                v.maxNativeFee,
                v.minAmountLD,
                v.nonce,
                v.deadline
            )
        );
    }

    function _send(SendVoucher calldata v, IERC20 token)
        internal
        returns (uint256 nativeFee, bytes32 guid, uint256 amountReceivedLD)
    {
        SendParam memory sendParam = SendParam({
            dstEid: v.dstEid,
            to: bytes32(uint256(uint160(v.to))),
            amountLD: v.amountLD - v.feeLD,
            minAmountLD: v.minAmountLD,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        nativeFee = IOFT(v.oft).quoteSend(sendParam, false).nativeFee;
        if (nativeFee > v.maxNativeFee) revert NativeFeeAboveVoucher();
        if (nativeFee > address(this).balance) revert InsufficientBalance();
        _spendDailyFee(nativeFee);

        token.forceApprove(v.oft, sendParam.amountLD);
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) =
            IOFT(v.oft).send{value: nativeFee}(sendParam, MessagingFee(nativeFee, 0), address(this));
        token.forceApprove(v.oft, 0);

        return (nativeFee, msgReceipt.guid, oftReceipt.amountReceivedLD);
    }

    function _spendDailyFee(uint256 fee) internal {
        uint256 day = block.timestamp / 1 days;
        if (day != feeDay) {
            feeDay = day;
            feeSpentToday = 0;
        }
        uint256 spent = feeSpentToday + fee;
        if (spent > dailyFeeBudget) revert DailyFeeBudgetExceeded();
        feeSpentToday = spent;
    }

    function _setVoucherSigner(address signer) internal {
        if (signer == address(0)) revert ZeroAddress();
        voucherSigner = signer;
        emit VoucherSignerUpdated(signer);
    }

    function _setFeeRecipient(address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    // ========================================= RESCUE =========================================

    function rescueNative(address to) external onlyOwner {
        (bool success,) = to.call{value: address(this).balance}("");
        if (!success) revert NativeTransferFailed();
    }

    function rescueTokens(address token, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    function approveERC20(address token, address spender, uint256 amount) external onlyOwner {
        IERC20(token).forceApprove(spender, amount);
    }

    receive() external payable {}

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
