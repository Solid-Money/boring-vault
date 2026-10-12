// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {AccessControlUpgradeable} from "@oz/access/AccessControlUpgradeable.sol";
import {Initializable} from "@oz/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@oz/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAccountant} from "../interfaces/IAccountant.sol";
import {IPriceAdapter} from "./interfaces/IPriceAdapter.sol";
import {ISolidPriceProviderV2, PriceFeedConfigV2, PriceFeedKindV2} from "./interfaces/ISolidPriceProviderV2.sol";

/**
 * @title SolidPriceProviderV2
 * @notice Upgrade of `SolidPriceProvider` adding market prices, a permanent extension point for any
 *         future oracle family, and a timestamp on every read.
 * @dev **Storage layout is deliberately compatible with the deployed implementation.** The first
 *      three storage variables keep their slots verbatim; `_adapterAllowed` consumes the first word
 *      of the old `__gap`, which the gap shrinks to pay for. `PriceFeedConfigV2` appends `pairIndex`
 *      to `PriceFeedConfig`, which is safe for a mapping value: each entry lives at
 *      `keccak256(key, slot)`, so extending the struct extends into that entry's own previously-zero
 *      region rather than colliding with a neighbour — and `pairIndex` in fact lands in the trailing
 *      padding of the third slot, so it costs no new slot at all.
 *
 *      **What is new, and why.**
 *
 *      1. `EXTERNAL_ADAPTER` — the only market-price family, and the escape hatch, so no oracle ever
 *         needs another upgrade of the contract that prices everyone's collateral. The previous
 *         implementation could not price a volatile asset at all: `STABLE` is a hardcoded peg and
 *         `VEDA_ACCOUNTANT` is a composition, and neither can price ETH. This is what WETH uses
 *         (and therefore what makes `soETH = exchangeRate(soETH->WETH) x price(WETH)` possible),
 *         and what a non-USD peg such as EURC uses — EURC's USD price floats with EUR/USD, so the
 *         adapter composes `peg_EUR x EURUSD` and this contract sees an ordinary market price.
 *
 *         An earlier revision carried a `SUPRA` family. **Supra is deprecated on Fuse**, the member
 *         was never written to storage on any chain, and its read and configuration paths are gone;
 *         the enum member survives only as a tombstone, because the enum is append-only and
 *         storage-shared.
 *      2. `STABLE_ADAPTER` — a peg an allowlisted adapter may mark **down** but never up, capped at
 *         `pegPriceUsd` by `_priceMarkedDownPeg`. Narrower than `EXTERNAL_ADAPTER` on purpose: the
 *         capability granted is "reduce this stablecoin's value", so a compromised adapter cannot
 *         inflate collateral, and an unusable one degrades to the peg instead of declining every
 *         card composed on top of it.
 *         **The privilege boundary is the whole point:** allowlisting an adapter is `UPGRADER_ROLE`
 *         (the timelocked multisig, i.e. exactly the bar an upgrade clears), while pointing a token
 *         at an already-allowlisted adapter stays `PRICE_ADMIN_ROLE`. Letting the day-to-day key
 *         name an arbitrary address would turn it into "can set any price" and collapse the
 *         two-role split this contract exists to maintain.
 *      3. `priceUsdDetailed` — returns the source's own last-update timestamp, so a consumer can
 *         enforce its **own** staleness bound. Without it a consumer's independent price checks
 *         catch an absurd value but not a stale-but-plausible one, which is the exploitable case
 *         for a volatile asset.
 *
 *      An adapter owns its source's native decimals and must return 6-decimal USD, exactly as
 *      `VEDA_ACCOUNTANT` owns `baseDecimals`. Assuming an accountant's base is dollars is the same
 *      class of error, and would misprice soETH by three orders of magnitude.
 */
contract SolidPriceProviderV2 is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ISolidPriceProviderV2 {
    using Math for uint256;

    // ========================================= CONSTANTS =========================================

    /// @notice Decimals every price returned by this contract is quoted in.
    uint8 public constant PRICE_DECIMALS = 6;

    /// @notice One whole unit at `PRICE_DECIMALS`, i.e. exactly $1.00.
    uint256 public constant ONE_USD = 10 ** 6;

    /// @notice Manages per-token feed configuration.
    bytes32 public constant PRICE_ADMIN_ROLE = keccak256("PRICE_ADMIN_ROLE");

    /// @notice Authorises implementation upgrades **and** the adapter allowlist. Timelocked multisig.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Gas forwarded to an `EXTERNAL_ADAPTER`.
     * @dev Bounds a hostile or buggy adapter's ability to gas-grief the authorize hot path, and
     *      contains an adapter that illegally calls back into this contract: the recursion exhausts
     *      the cap and the read fails closed rather than dangerously. Generous enough for any honest
     *      adapter (a Chainlink `latestRoundData` read plus arithmetic is well under 30k).
     */
    uint256 public constant ADAPTER_GAS_LIMIT = 200_000;

    /**
     * @notice Gas forwarded to a `VEDA_ACCOUNTANT` source.
     * @dev Read the same way an adapter is, for the same reasons: a high-level call
     *      forwards all remaining gas and propagates both a revert and a return-data decode failure,
     *      either of which would break this contract's never-reverts contract and take the
     *      consumer's whole position valuation down with it.
     */
    uint256 public constant SOURCE_GAS_LIMIT = 200_000;

    // ========================================= STORAGE =========================================
    // WARNING: the first three variables MUST keep their slots — they are shared with the deployed
    // implementation. New variables consume the old __gap, which shrinks to pay for them.

    mapping(address => PriceFeedConfigV2) internal _configs;

    /// @dev Enumeration for the lens and for ops review of the full configured set.
    address[] internal _configuredTokens;
    mapping(address => bool) internal _isConfigured;

    /// @notice Adapters an `EXTERNAL_ADAPTER` config may reference. `UPGRADER_ROLE` gated.
    mapping(address => bool) internal _adapterAllowed;

    /// @dev Was `uint256[45]`; one word paid for `_adapterAllowed`.
    uint256[44] private __gap;

    // ========================================= ERRORS =========================================

    error InvalidInput();
    error InvalidPriceBand();
    error PegPriceOutsideBand();
    error UnsupportedFeedKind();
    error AccountantVaultMismatch();
    error AccountantBaseMismatch();
    error TokenDecimalsMismatch();
    error BaseAssetNotConfigured();
    error BaseAssetMustNotBeComposed();
    error TokenIsUsedAsABase();
    error AdapterNotAllowed();
    error UncorroboratedPeg();

    // ========================================= EVENTS =========================================

    event TokenConfigSet(address indexed token, PriceFeedKindV2 kind, address source, address baseAsset);
    event TokenConfigRemoved(address indexed token);
    event AdapterAllowanceSet(address indexed adapter, bool allowed);
    event BarePegSet(address indexed token, uint96 pegPriceUsd);

    // ========================================= INITIALIZER =========================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Fresh-deployment initializer. Not used when upgrading the live proxy, which already
     *         has its roles set; `_authorizeUpgrade` is the only gate that matters there.
     */
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidInput();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PRICE_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    // ========================================= PRICING =========================================

    /// @inheritdoc ISolidPriceProviderV2
    function priceUsd(address token) public view returns (uint256 price, bool usable) {
        (price, usable,) = priceUsdDetailed(token);
    }

    /**
     * @inheritdoc ISolidPriceProviderV2
     * @dev Never reverts, and this is now true for **every** family rather than only for adapters.
     *      Unconfigured token, paused accountant, stale rate, unusable base asset, zero price,
     *      unknown feed kind written by a newer implementation, hostile adapter, a source that
     *      reverts or runs long or returns short data — all of it collapses to `(0, false, 0)`, so
     *      an aggregating caller can attribute the failure to one token and still answer inside its
     *      latency budget.
     *
     *      That property is load-bearing rather than cosmetic: the consumer's `_positionValue` walks
     *      every allowlisted token, and the lens walks it twice more per authorize read. One
     *      propagating revert on an asset a user does not even hold would decline every card
     *      transaction for every user.
     */
    function priceUsdDetailed(address token) public view returns (uint256 price, bool usable, uint64 updatedAt) {
        PriceFeedConfigV2 memory config = _configs[token];

        if (config.kind == PriceFeedKindV2.STABLE) {
            // A bare peg. The price IS the constant, so there is nothing to observe: no band can
            // filter it — the only value it can ever return is the one a human already placed
            // inside the band — and `block.timestamp` makes every staleness bound pass by
            // construction. Both defensive layers are inert for it, which is why `setTokenConfig`
            // cannot create one and only `setBarePeg` (`UPGRADER_ROLE`) can.
            price = uint256(config.pegPriceUsd);
            updatedAt = uint64(block.timestamp);
        } else if (config.kind == PriceFeedKindV2.STABLE_ADAPTER) {
            (price, updatedAt) = _priceMarkedDownPeg(token, config);
        } else if (config.kind == PriceFeedKindV2.VEDA_ACCOUNTANT) {
            (price, usable, updatedAt) = _priceVedaShare(config);
            if (!usable) return (0, false, 0);
        } else if (config.kind == PriceFeedKindV2.EXTERNAL_ADAPTER) {
            (price, usable, updatedAt) = _priceAdapter(token, config);
            if (!usable) return (0, false, 0);
        } else {
            // NONE, or a kind written by a newer implementation than this one understands.
            return (0, false, 0);
        }

        // The universal backstop: whatever the feed computed has to sit inside a band a human set.
        if (price == 0 || price < config.minPriceUsd || price > config.maxPriceUsd) return (0, false, 0);

        return (price, true, updatedAt);
    }

    /**
     * @dev Reads an accountant under a gas cap, treating any failure as "unusable".
     *
     *      A raw `staticcall` rather than a high-level call, for the same two reasons an adapter
     *      gets one: a high-level call forwards all remaining gas, and it propagates both a revert
     *      and a return-data decode failure. Either would break this contract's never-reverts
     *      contract — and a revert here does not stay here: it reaches the consumer's
     *      `_positionValue`, which walks every allowlisted token for every user on the authorize
     *      path, so one misbehaving accountant would decline every card transaction in the system.
     *
     *      Returns false for a paused accountant too, so the caller has one thing to check.
     */
    function _readAccountant(address source) private view returns (uint96 exchangeRate, uint64 lastUpdate, bool ok) {
        (bool success, bytes memory ret) =
            source.staticcall{gas: SOURCE_GAS_LIMIT}(abi.encodeWithSelector(IAccountant.accountantState.selector));
        // `accountantState` returns twelve static values, i.e. exactly twelve words.
        if (!success || ret.length != 384) return (0, 0, false);

        uint256 rate;
        uint256 updated;
        uint256 pausedFlag;
        assembly ("memory-safe") {
            // Word i of the returned tuple lives at `ret + 0x20 + i*0x20`.
            rate := mload(add(ret, 0xa0)) // exchangeRate, index 4
            updated := mload(add(ret, 0x100)) // lastUpdateTimestamp, index 7
            pausedFlag := mload(add(ret, 0x120)) // isPaused, index 8
        }

        // Read raw, so anything a non-conforming source left in the high bits is rejected rather
        // than truncated into a plausible-looking value.
        if (rate == 0 || rate > type(uint96).max) return (0, 0, false);
        if (updated > type(uint64).max || pausedFlag != 0) return (0, 0, false);

        return (uint96(rate), uint64(updated), true);
    }

    /**
     * @dev Prices a Veda / BoringVault share as `exchangeRate x price(baseAsset)`.
     *
     *      `exchangeRate` is quoted in base-asset units per one whole share, so dividing by the base
     *      asset's decimals — not the share's — is what makes this correct for both a 6-decimal
     *      USDC-based vault and an 18-decimal WETH-based one.
     *
     *      The returned timestamp is the **older** of the accountant's own update and the base
     *      asset's, because a composed price is only as fresh as its stalest input.
     */
    function _priceVedaShare(PriceFeedConfigV2 memory config) private view returns (uint256, bool, uint64) {
        (uint96 exchangeRate, uint64 lastUpdateTimestamp, bool ok) = _readAccountant(config.source);
        if (!ok) return (0, false, 0);

        // Guard the subtraction: a future-dated timestamp would otherwise revert this view.
        uint256 age = block.timestamp > lastUpdateTimestamp ? block.timestamp - lastUpdateTimestamp : 0;
        if (age > config.maxStaleness) return (0, false, 0);

        // One hop only (enforced in setTokenConfig), so this cannot recurse further.
        (uint256 basePrice, bool baseUsable, uint64 baseUpdatedAt) = priceUsdDetailed(config.baseAsset);
        if (!baseUsable) return (0, false, 0);

        uint64 composed = baseUpdatedAt < lastUpdateTimestamp ? baseUpdatedAt : lastUpdateTimestamp;

        return (uint256(exchangeRate).mulDiv(basePrice, 10 ** config.baseDecimals, Math.Rounding.Floor), true, composed);
    }

    /**
     * @dev A USD peg an adapter may mark **down**, never up.
     *
     *      This is the whole reason `STABLE_ADAPTER` is a separate family from `EXTERNAL_ADAPTER`
     *      rather than a configuration of it. The quote is `min(peg, observed)`, capped **here**,
     *      so the capability the adapter is granted is "reduce this stablecoin's value" and not
     *      "set it". A compromised or buggy writer key behind such an adapter therefore costs users
     *      borrowing power and cannot inflate anyone's collateral — a bounded, recoverable failure
     *      rather than a solvency one.
     *
     *      **An unusable adapter degrades to the peg rather than to a decline.** A veto that any
     *      third party can trigger is a denial of service, not a safety property: an unpriceable
     *      stablecoin takes down every position composed on top of it — and soUSD is composed on
     *      USDC.e — which declines every card in the system. Falling back to the peg is exactly the
     *      behaviour of a bare `STABLE` entry, so the failure mode is "no worse than an
     *      uncorroborated peg", and it is the off-chain monitor's job to page someone.
     *
     *      The residual risk is stated plainly: if the adapter is down **and** the peg genuinely
     *      breaks at the same moment, this prices at par. Bounding that is the module's
     *      `minPriceUsd` floor and the guardian's `setTokenPaused`, not this function.
     */
    function _priceMarkedDownPeg(address token, PriceFeedConfigV2 memory config)
        private
        view
        returns (uint256, uint64)
    {
        uint256 peg = uint256(config.pegPriceUsd);

        (uint256 observed, bool ok, uint64 observedAt) = _priceAdapter(token, config);
        if (!ok) return (peg, uint64(block.timestamp));

        return (observed < peg ? observed : peg, observedAt);
    }

    /**
     * @dev Reads an allowlisted adapter under a bounded `staticcall`.
     *
     *      Written as a raw `staticcall` rather than `try IPriceAdapter(...).price(...)` for two
     *      reasons. First, the gas cap: `try/catch` forwards all remaining gas, so a hostile adapter
     *      could burn the authorize path's entire budget or recurse into this contract. Second,
     *      Solidity's `try/catch` does not catch a failure to *decode* the return data, so an
     *      address with no code — which succeeds and returns nothing — would propagate a decode
     *      revert straight past the `catch` and break this function's never-reverts contract.
     *
     *      Any failure at all is `(0, false, 0)`: revert, out-of-gas, short return data, no code.
     */
    function _priceAdapter(address token, PriceFeedConfigV2 memory config)
        private
        view
        returns (uint256, bool, uint64)
    {
        // Re-checked on read, not merely at configuration time, so de-allowlisting an adapter takes
        // effect immediately for every token already pointed at it.
        if (!_adapterAllowed[config.source]) return (0, false, 0);

        (bool ok, bytes memory ret) = config.source.staticcall{gas: ADAPTER_GAS_LIMIT}(
            abi.encodeWithSelector(IPriceAdapter.price.selector, token)
        );

        // A well-formed `(uint256, bool, uint64)` return is exactly three words. Checking the length
        // before decoding is what makes a no-code address safe: such a call *succeeds* and returns
        // nothing, and `abi.decode` on empty data reverts.
        if (!ok || ret.length != 96) return (0, false, 0);

        (uint256 price, bool usable, uint64 updatedAt) = abi.decode(ret, (uint256, bool, uint64));
        if (!usable || price == 0) return (0, false, 0);

        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > config.maxStaleness) return (0, false, 0);

        return (price, true, updatedAt);
    }

    /**
     * @notice Converts a USD amount into token units at the current price, rounding up.
     * @dev Rounds up so a remainder can never leave the settlement destination short of the USD it
     *      is owed; the payer bears at most one token unit of rounding.
     */
    function tokenAmountForUsd(address token, uint256 amountUsd)
        external
        view
        returns (uint256 tokenAmount, bool usable)
    {
        (uint256 price, bool priceUsable) = priceUsd(token);
        if (!priceUsable) return (0, false);

        return (amountUsd.mulDiv(10 ** _configs[token].tokenDecimals, price, Math.Rounding.Ceil), true);
    }

    /// @notice Converts a token amount into its USD value at the current price, rounding down.
    function usdValueOfToken(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 amountUsd, bool usable)
    {
        (uint256 price, bool priceUsable) = priceUsd(token);
        if (!priceUsable) return (0, false);

        return (tokenAmount.mulDiv(price, 10 ** _configs[token].tokenDecimals, Math.Rounding.Floor), true);
    }

    // ========================================= CONFIGURATION =========================================

    /**
     * @notice Allowlists or de-allowlists an `EXTERNAL_ADAPTER`. **`UPGRADER_ROLE` only.**
     * @dev Deliberately not `PRICE_ADMIN_ROLE`. Introducing a new price source is exactly as
     *      privileged as shipping new pricing code, so it clears the same bar; letting the
     *      day-to-day configuration key name an arbitrary contract would make that key equivalent to
     *      "can set any price" and collapse the two-role split.
     *
     *      De-allowlisting is immediate and is read on every price evaluation, so it is the fast
     *      response to a compromised adapter. Tokens pointed at it become unpriceable, which is
     *      fail-closed: they stop contributing to spending power and to borrowing power.
     */
    function setAdapterAllowed(address adapter, bool allowed) external onlyRole(UPGRADER_ROLE) {
        if (adapter == address(0)) revert InvalidInput();
        _adapterAllowed[adapter] = allowed;
        emit AdapterAllowanceSet(adapter, allowed);
    }

    /// @inheritdoc ISolidPriceProviderV2
    function isAdapterAllowed(address adapter) external view returns (bool) {
        return _adapterAllowed[adapter];
    }

    /**
     * @notice Configures or replaces the feed for a token.
     * @dev Every cross-field relationship is validated here rather than trusted, because a
     *      misconfiguration is indistinguishable from a correct configuration at read time and would
     *      simply misprice the asset.
     */
    function setTokenConfig(address token, PriceFeedConfigV2 calldata config) external onlyRole(PRICE_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidInput();
        if (config.minPriceUsd == 0 || config.maxPriceUsd < config.minPriceUsd) revert InvalidPriceBand();
        if (config.tokenDecimals != ERC20(token).decimals()) revert TokenDecimalsMismatch();

        if (config.kind == PriceFeedKindV2.STABLE) {
            // A bare peg cannot be checked by anything, here or downstream, so the day-to-day
            // configuration key may not create one. `setBarePeg` can, at `UPGRADER_ROLE`; the read
            // path still honours the entries the previous implementation wrote, so upgrading the
            // live proxy orphans nothing. Use `STABLE_ADAPTER` for anything new.
            revert UncorroboratedPeg();
        } else if (config.kind == PriceFeedKindV2.STABLE_ADAPTER) {
            if (config.pegPriceUsd < config.minPriceUsd || config.pegPriceUsd > config.maxPriceUsd) {
                revert PegPriceOutsideBand();
            }
            if (config.source == address(0) || config.maxStaleness == 0) revert InvalidInput();
            // The day-to-day key may only point at something the timelocked key already vouched for.
            if (!_adapterAllowed[config.source]) revert AdapterNotAllowed();
            // Prove the adapter answers, and answers in band, before a token depends on it.
            (uint256 pegProbe, bool pegProbeOk,) = _priceAdapter(token, config);
            if (!pegProbeOk || pegProbe < config.minPriceUsd || pegProbe > config.maxPriceUsd) {
                revert InvalidInput();
            }
        } else if (config.kind == PriceFeedKindV2.VEDA_ACCOUNTANT) {
            if (config.source == address(0) || config.maxStaleness == 0) revert InvalidInput();

            IAccountant accountant = IAccountant(config.source);
            if (accountant.vault() != token) revert AccountantVaultMismatch();
            if (accountant.base() != config.baseAsset) revert AccountantBaseMismatch();
            if (config.baseDecimals != ERC20(config.baseAsset).decimals()) revert TokenDecimalsMismatch();

            // The one-hop rule, enforced in both directions. Checking only that *my* base is not
            // composed is not enough: a token already serving as someone else's base could later be
            // converted into a composed feed, silently lengthening that chain.
            //
            // Depth is what this bounds. A cycle is already impossible either way — closing one
            // always requires naming an already-composed token as a base, which is rejected — but an
            // unbounded chain would put N recursive calls on the authorize path's single read, where
            // the failure mode is a gas-exhausted decline rather than a wrong price.
            //
            // Every non-composing family is a legal base, which is what keeps the two chains this
            // system actually needs one hop long: soUSD -> USDC.e (a peg, bare or marked down) and
            // soETH -> WETH (an EXTERNAL_ADAPTER market price).
            PriceFeedKindV2 baseKind = _configs[config.baseAsset].kind;
            if (baseKind == PriceFeedKindV2.NONE) revert BaseAssetNotConfigured();
            if (baseKind == PriceFeedKindV2.VEDA_ACCOUNTANT) revert BaseAssetMustNotBeComposed();
            if (_isUsedAsBase(token)) revert TokenIsUsedAsABase();
        } else if (config.kind == PriceFeedKindV2.EXTERNAL_ADAPTER) {
            if (config.source == address(0) || config.maxStaleness == 0) revert InvalidInput();
            // The day-to-day key may only point at something the timelocked key already vouched for.
            if (!_adapterAllowed[config.source]) revert AdapterNotAllowed();
            (uint256 probe, bool probeOk,) = _priceAdapter(token, config);
            if (!probeOk || probe < config.minPriceUsd || probe > config.maxPriceUsd) revert InvalidInput();
        } else {
            revert UnsupportedFeedKind();
        }

        _write(token, config);
    }

    /**
     * @notice Writes a bare, uncorroborated `STABLE` peg. **`UPGRADER_ROLE` only.**
     * @dev Deliberately not `PRICE_ADMIN_ROLE`, and deliberately not reachable through
     *      `setTokenConfig`. A bare peg is the one price neither this contract's band nor a
     *      consumer's staleness bound can filter, so creating one is a decision about what this
     *      system is willing to assert without evidence — the same class of decision as shipping
     *      new pricing code, and it clears the same bar.
     *
     *      It exists rather than being removed outright for two reasons. A fresh deployment (a new
     *      chain, or a testnet rehearsal) has no legacy entry to inherit, and soUSD cannot be
     *      configured at all until its accountant base is — so without this, `VEDA_ACCOUNTANT`
     *      would be unusable anywhere the live proxy's history is absent. And the live USDC.e entry
     *      may one day need its band widened, which would otherwise require standing up an oracle
     *      to change a constant.
     *
     *      Prefer `STABLE_ADAPTER` whenever there is anything at all to observe.
     */
    function setBarePeg(address token, PriceFeedConfigV2 calldata config) external onlyRole(UPGRADER_ROLE) {
        if (token == address(0)) revert InvalidInput();
        if (config.kind != PriceFeedKindV2.STABLE) revert UnsupportedFeedKind();
        // A bare peg observes nothing, so anything that names a source or a staleness bound is a
        // misconfiguration rather than a stricter one: it would read as those fields being honoured.
        if (config.source != address(0) || config.maxStaleness != 0) revert InvalidInput();
        if (config.minPriceUsd == 0 || config.maxPriceUsd < config.minPriceUsd) revert InvalidPriceBand();
        if (config.tokenDecimals != ERC20(token).decimals()) revert TokenDecimalsMismatch();
        if (config.pegPriceUsd < config.minPriceUsd || config.pegPriceUsd > config.maxPriceUsd) {
            revert PegPriceOutsideBand();
        }

        _write(token, config);
        emit BarePegSet(token, config.pegPriceUsd);
    }

    function _write(address token, PriceFeedConfigV2 memory config) private {
        _configs[token] = config;

        if (!_isConfigured[token]) {
            _isConfigured[token] = true;
            _configuredTokens.push(token);
        }

        emit TokenConfigSet(token, config.kind, config.source, config.baseAsset);
    }

    /**
     * @notice Removes a token's feed, making it unpriceable.
     * @dev Refuses while another configured token is composed on top of this one, which would
     *      otherwise turn that token unpriceable as a side effect of an unrelated change.
     */
    function removeTokenConfig(address token) external onlyRole(PRICE_ADMIN_ROLE) {
        if (!_isConfigured[token]) revert InvalidInput();
        if (_isUsedAsBase(token)) revert TokenIsUsedAsABase();

        delete _configs[token];
        _isConfigured[token] = false;

        uint256 length = _configuredTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_configuredTokens[i] == token) {
                _configuredTokens[i] = _configuredTokens[length - 1];
                _configuredTokens.pop();
                break;
            }
        }

        emit TokenConfigRemoved(token);
    }

    /**
     * @notice Whether any configured token is priced on top of `token`.
     * @dev Linear in the configured set, which is small and only walked on configuration writes —
     *      never on the pricing path. `EXTERNAL_ADAPTER` stores its own token in `baseAsset`, so it
     *      is excluded explicitly rather than counting itself as its own dependent.
     */
    function isUsedAsBase(address token) external view returns (bool) {
        return _isUsedAsBase(token);
    }

    function _isUsedAsBase(address token) private view returns (bool) {
        uint256 length = _configuredTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            address other = _configuredTokens[i];
            if (
                other != token && _configs[other].kind == PriceFeedKindV2.VEDA_ACCOUNTANT
                    && _configs[other].baseAsset == token
            ) return true;
        }

        return false;
    }

    // ========================================= VIEWS =========================================

    /// @inheritdoc ISolidPriceProviderV2
    function getConfig(address token) external view returns (PriceFeedConfigV2 memory) {
        return _configs[token];
    }

    /// @inheritdoc ISolidPriceProviderV2
    function configuredTokens() external view returns (address[] memory) {
        return _configuredTokens;
    }

    /// @notice Prices several tokens in one call, for ops dashboards.
    function priceUsdBatch(address[] calldata tokens)
        external
        view
        returns (uint256[] memory prices, bool[] memory usable)
    {
        prices = new uint256[](tokens.length);
        usable = new bool[](tokens.length);

        for (uint256 i = 0; i < tokens.length; ++i) {
            (prices[i], usable[i]) = priceUsd(tokens[i]);
        }
    }

    // ========================================= UPGRADE =========================================

    /// @dev Restricted to `UPGRADER_ROLE`, intended to be the timelocked multisig and deliberately
    ///      not the key that manages day-to-day token configuration. No zero-address check is
    ///      needed: `ERC1967Utils` already rejects an implementation with no code.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
