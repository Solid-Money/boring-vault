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
 *
 *      `lifiCall` is the one entrypoint that forwards calldata it did not build: a LI.FI swap that
 *      crosses into or out of Fuse over Stargate, whose native fee this contract pays. It keeps the
 *      rules above by other means. The calldata must be the exact bytes the backend signed into a
 *      voucher, for one of two LI.FI Stargate functions, and is decoded and checked here as well:
 *      the coins go to the caller, Stargate refunds to this contract, the fee forwarded is the
 *      fee the calldata pays, no LayerZero option drops native anywhere, and the user's own coin
 *      is the only asset pulled. The fee is capped per call and per day.
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
        STARGATE_OFT,
        LIFI_DIAMOND
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
     * @notice A backend-signed authorisation for one `lifiCall`.
     * @dev Signed by `voucherSigner` under the same domain as `SendVoucher`, from the LI.FI quote
     *      the user reviewed: the calldata is fixed by `dataHash`, so nothing in it can change.
     * @param from The Safe allowed to spend this voucher; must be `msg.sender`.
     * @param target The LI.FI diamond, registered as `LIFI_DIAMOND`.
     * @param token The coin the swap takes from `from`; `address(0)` for the native coin.
     * @param amount How much of `token` the swap takes: pulled from `from`, or its `msg.value`.
     * @param dataHash `keccak256` of the LI.FI calldata.
     * @param nativeFee The Stargate fee this contract pays on top: the calldata's
     *        `StargateData.fee.nativeFee`.
     * @param nonce Unique per voucher, shared with `SendVoucher`; spent on use.
     * @param deadline Last timestamp the voucher can be used at.
     */
    struct LifiVoucher {
        address from;
        address target;
        address token;
        uint256 amount;
        bytes32 dataHash;
        uint256 nativeFee;
        uint256 nonce;
        uint64 deadline;
    }

    bytes32 public constant LIFI_VOUCHER_TYPEHASH = keccak256(
        "LifiVoucher(address from,address target,address token,uint256 amount,bytes32 dataHash,uint256 nativeFee,uint256 nonce,uint64 deadline)"
    );

    /// @dev LI.FI's `ILiFi.BridgeData`, field for field.
    struct LifiBridgeData {
        bytes32 transactionId;
        string bridge;
        string integrator;
        address referrer;
        address sendingAssetId;
        address receiver;
        uint256 minAmount;
        uint256 destinationChainId;
        bool hasSourceSwaps;
        bool hasDestinationCall;
    }

    /// @dev LI.FI's `LibSwap.SwapData`, field for field.
    struct LifiSwapData {
        address callTo;
        address approveTo;
        address sendingAssetId;
        address receivingAssetId;
        uint256 fromAmount;
        bytes callData;
        bool requiresDeposit;
    }

    /// @dev LI.FI's `StargateFacetV2.StargateData`, field for field.
    struct LifiStargateData {
        uint16 assetId;
        SendParam sendParams;
        MessagingFee fee;
        address refundAddress;
    }

    /// @dev `StargateFacetV2.swapAndStartBridgeTokensViaStargate(BridgeData,SwapData[],StargateData)`.
    bytes4 internal constant LIFI_SWAP_AND_BRIDGE_VIA_STARGATE = 0xa6010a66;
    /// @dev `StargateFacetV2.startBridgeTokensViaStargate(BridgeData,StargateData)`.
    bytes4 internal constant LIFI_BRIDGE_VIA_STARGATE = 0x14d53077;
    /// @dev Most distinct coins a LI.FI route's source swaps may take, so the refund loop is bounded.
    uint256 internal constant MAX_LIFI_INPUTS = 4;
    /// @dev LayerZero's executor, in type-3 options.
    uint8 internal constant LZ_EXECUTOR_WORKER = 1;

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
    event LifiCallSponsored(
        address indexed from,
        address indexed target,
        uint256 indexed nonce,
        address token,
        uint256 amount,
        uint256 nativeFee,
        bytes32 transactionId
    );
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
    error UnsupportedCall();
    error CalldataMismatch();
    error ReceiverNotCaller();
    error InputMismatch();
    error RefundNotToPaymaster();
    error NativeDropNotAllowed();
    error ValueMismatch();
    error FeeMismatch();

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

    /**
     * @notice Run a LI.FI swap that crosses between Fuse and another chain over Stargate, paying
     *         the native fee Stargate charges on top.
     * @dev The caller approves this contract for `v.amount` of `v.token`, or sends it as
     *      `msg.value` when it is the native coin. This contract pulls it, approves the diamond for
     *      exactly that much, and calls it with `data` and `msg.value + v.nativeFee`. Whatever LI.FI
     *      hands back within the call - unspent input, swap leftovers, native - goes on to the
     *      caller before this returns; native only up to what the caller sent, since the rest is
     *      Stargate repaying a fee this contract paid.
     * @return transactionId LI.FI's id for the transfer, which its status API tracks it by.
     */
    function lifiCall(LifiVoucher calldata v, bytes calldata data, bytes calldata signature)
        external
        payable
        nonReentrant
        onlyTarget(v.target, TargetKind.LIFI_DIAMOND)
        returns (bytes32 transactionId)
    {
        _useLifiVoucher(v, signature);
        if (keccak256(data) != v.dataHash) revert CalldataMismatch();
        if (msg.value != (v.token == address(0) ? v.amount : 0)) revert ValueMismatch();
        if (v.nativeFee > maxSponsoredAmount[v.target]) revert AmountAboveMaximum();

        address[] memory inputs;
        (transactionId, inputs) = _checkLifiRoute(v, data);
        _payAndCallLifi(v, data, inputs);

        emit LifiCallSponsored(v.from, v.target, v.nonce, v.token, v.amount, v.nativeFee, transactionId);
    }

    /**
     * @notice The EIP-712 digest a voucher signer signs for `v`.
     * @dev Exposed so the backend can check its encoding against the contract's.
     */
    function hashLifiVoucher(LifiVoucher calldata v) external view returns (bytes32) {
        return _hashTypedDataV4(_lifiVoucherStructHash(v));
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

    function _useLifiVoucher(LifiVoucher calldata v, bytes calldata signature) internal {
        if (v.from != msg.sender) revert VoucherNotForCaller();
        if (block.timestamp > v.deadline) revert VoucherExpired();
        if (usedNonce[v.nonce]) revert VoucherUsed();
        if (ECDSA.recover(_hashTypedDataV4(_lifiVoucherStructHash(v)), signature) != voucherSigner) {
            revert InvalidVoucherSignature();
        }
        usedNonce[v.nonce] = true;
    }

    function _lifiVoucherStructHash(LifiVoucher calldata v) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LIFI_VOUCHER_TYPEHASH, v.from, v.target, v.token, v.amount, v.dataHash, v.nativeFee, v.nonce, v.deadline
            )
        );
    }

    /**
     * @dev Decodes the LI.FI call and refuses anything but a Stargate transfer that delivers to
     *      the caller, refunds to this contract, pays exactly the voucher's fee with no native
     *      riding on its options, and takes the caller's coin in the voucher's amount. Returns
     *      LI.FI's transaction id and the distinct ERC-20s the route takes, for the refund.
     */
    function _checkLifiRoute(LifiVoucher calldata v, bytes calldata data)
        internal
        view
        returns (bytes32 transactionId, address[] memory inputs)
    {
        if (data.length < 4) revert UnsupportedCall();
        bytes4 selector = bytes4(data[:4]);
        LifiBridgeData memory bridgeData;
        LifiSwapData[] memory swaps;
        LifiStargateData memory stargateData;
        if (selector == LIFI_SWAP_AND_BRIDGE_VIA_STARGATE) {
            (bridgeData, swaps, stargateData) = abi.decode(data[4:], (LifiBridgeData, LifiSwapData[], LifiStargateData));
            if (swaps.length == 0) revert InputMismatch();
        } else if (selector == LIFI_BRIDGE_VIA_STARGATE) {
            (bridgeData, stargateData) = abi.decode(data[4:], (LifiBridgeData, LifiStargateData));
        } else {
            revert UnsupportedCall();
        }

        if (bridgeData.receiver != v.from) revert ReceiverNotCaller();
        if (bridgeData.destinationChainId == block.chainid) revert RouteNotAllowed();
        if (!allowedDstEid[v.target][stargateData.sendParams.dstEid]) revert RouteNotAllowed();

        // The first thing LI.FI takes is the caller's coin: the first swap's input, or with no
        // swaps the bridged asset itself.
        (address takes, uint256 amount) = swaps.length > 0
            ? (swaps[0].sendingAssetId, swaps[0].fromAmount)
            : (bridgeData.sendingAssetId, bridgeData.minAmount);
        if (takes != v.token || amount != v.amount) revert InputMismatch();

        if (stargateData.fee.nativeFee != v.nativeFee || stargateData.fee.lzTokenFee != 0) {
            revert FeeMismatch();
        }
        if (stargateData.refundAddress != address(this)) revert RefundNotToPaymaster();
        _requireNoNativeOptions(stargateData.sendParams.extraOptions);

        inputs = _lifiInputs(bridgeData.sendingAssetId, swaps);
        transactionId = bridgeData.transactionId;
    }

    /**
     * @dev Refuses LayerZero options that move native: a native drop, or value sent along with
     *      the receive or compose call. Either would be priced into the fee this contract pays
     *      and land wherever the options say. Gas limits only price execution, so they pass.
     *      Type 1 options are a gas limit alone; type 2 carry an airdrop and are refused.
     */
    function _requireNoNativeOptions(bytes memory options) internal pure {
        if (options.length == 0) return;
        if (options.length < 2) revert NativeDropNotAllowed();
        uint256 kind = (uint256(uint8(options[0])) << 8) | uint8(options[1]);
        if (kind == 1) return;
        if (kind != 3) revert NativeDropNotAllowed();

        // Type 3: [worker uint8][size uint16][optionType uint8][params: size - 1 bytes], repeated.
        uint256 cursor = 2;
        while (cursor < options.length) {
            if (cursor + 4 > options.length) revert NativeDropNotAllowed();
            uint8 worker = uint8(options[cursor]);
            uint256 size = (uint256(uint8(options[cursor + 1])) << 8) | uint8(options[cursor + 2]);
            if (size == 0 || cursor + 3 + size > options.length) revert NativeDropNotAllowed();
            if (worker == LZ_EXECUTOR_WORKER) {
                uint8 optionType = uint8(options[cursor + 3]);
                uint256 params = cursor + 4;
                // lzReceive: gas uint128, then an optional native value.
                if (optionType == 1) {
                    _requireZero(options, params + 16, cursor + 3 + size);
                }
                // lzCompose: index uint16, gas uint128, then an optional native value.
                else if (optionType == 3) {
                    _requireZero(options, params + 18, cursor + 3 + size);
                }
                // Ordered execution carries nothing; anything else (a native drop) is refused.
                else if (optionType != 4) {
                    revert NativeDropNotAllowed();
                }
            }
            cursor += 3 + size;
        }
    }

    function _requireZero(bytes memory data, uint256 from, uint256 to) internal pure {
        for (uint256 i = from; i < to; i++) {
            if (data[i] != 0) revert NativeDropNotAllowed();
        }
    }

    /// @dev The distinct ERC-20s a LI.FI route takes from its caller: each swap's input, and the
    ///      bridged asset.
    function _lifiInputs(address bridged, LifiSwapData[] memory swaps) internal pure returns (address[] memory inputs) {
        address[] memory found = new address[](swaps.length + 1);
        uint256 count;
        for (uint256 i; i <= swaps.length; i++) {
            address asset = i < swaps.length ? swaps[i].sendingAssetId : bridged;
            if (asset == address(0)) continue;
            bool seen;
            for (uint256 j; j < count; j++) {
                if (found[j] == asset) {
                    seen = true;
                    break;
                }
            }
            if (!seen) found[count++] = asset;
        }
        if (count > MAX_LIFI_INPUTS) revert UnsupportedCall();
        inputs = new address[](count);
        for (uint256 i; i < count; i++) {
            inputs[i] = found[i];
        }
    }

    /**
     * @dev Pays the fee, runs the LI.FI call and refunds what it left. `before` is taken before the
     *      caller's coin arrives, so whatever of it LI.FI leaves counts as theirs.
     */
    function _payAndCallLifi(LifiVoucher calldata v, bytes calldata data, address[] memory inputs) internal {
        uint256 nativeFloor = address(this).balance - msg.value;
        if (v.nativeFee > nativeFloor) revert InsufficientBalance();
        nativeFloor -= v.nativeFee;
        _spendDailyFee(v.nativeFee);

        uint256[] memory before = new uint256[](inputs.length);
        for (uint256 i; i < inputs.length; i++) {
            before[i] = IERC20(inputs[i]).balanceOf(address(this));
        }

        if (v.token != address(0)) {
            IERC20(v.token).safeTransferFrom(msg.sender, address(this), v.amount);
            IERC20(v.token).forceApprove(v.target, v.amount);
        }
        (bool success, bytes memory result) = v.target.call{value: msg.value + v.nativeFee}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        if (v.token != address(0)) IERC20(v.token).forceApprove(v.target, 0);

        _refundLifiLeftovers(v.from, inputs, before, nativeFloor, msg.value);
    }

    /**
     * @dev Sends `to` whatever the call left here: each input coin above its balance before the
     *      call, and native above `nativeFloor` (this contract's own balance less the fee it paid),
     *      up to `nativeIn`, the native the caller sent.
     */
    function _refundLifiLeftovers(
        address to,
        address[] memory inputs,
        uint256[] memory before,
        uint256 nativeFloor,
        uint256 nativeIn
    ) internal {
        for (uint256 i; i < inputs.length; i++) {
            uint256 balance = IERC20(inputs[i]).balanceOf(address(this));
            if (balance > before[i]) IERC20(inputs[i]).safeTransfer(to, balance - before[i]);
        }
        uint256 nativeBalance = address(this).balance;
        uint256 back = nativeBalance > nativeFloor ? nativeBalance - nativeFloor : 0;
        uint256 owed = back < nativeIn ? back : nativeIn;
        if (owed > 0) {
            (bool success,) = to.call{value: owed}("");
            if (!success) revert NativeTransferFailed();
        }
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
