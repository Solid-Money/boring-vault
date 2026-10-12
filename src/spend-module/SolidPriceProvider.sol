// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {AccessControlUpgradeable} from "@oz/access/AccessControlUpgradeable.sol";
import {Initializable} from "@oz/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@oz/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

import {IAccountant} from "./interfaces/IAccountant.sol";
import {ISolidPriceProvider, PriceFeedConfig, PriceFeedKind} from "./interfaces/ISolidPriceProvider.sol";

/**
 * @title SolidPriceProvider
 * @notice One upgradeable place every spend-module price is configured and evaluated.
 * @dev Modelled on ether.fi's `PriceProviderV2`: a `token -> config` registry with a feed-kind
 *      discriminator, so onboarding an asset is a configuration transaction rather than a deploy.
 *
 *      **Why this is upgradeable while `SolidCashModule` is not.** The module can move user funds, so
 *      it is deliberately non-upgradeable — migration there requires each Safe owner to re-enable a
 *      new module, which is the point. Pricing is different: new feed families (Chainlink, Pyth,
 *      redstone, an LP-share valuation) cannot be enumerated in advance, and being unable to add one
 *      without a per-user re-consent migration would be its own risk. So the extensible half is
 *      upgradeable and the fund-moving half is not.
 *
 *      **That split creates a trust vector, and it is deliberately not the only line of defence.** An
 *      upgrade to this contract could in principle report any price, which for a fixed USD debit
 *      translates directly into over- or under-collecting a user's tokens. Three things bound it:
 *
 *        1. `SolidCashModule` keeps its **own** per-token sanity band and re-checks every price it
 *           receives. A provider that returns an absurd value is rejected by the consumer, not
 *           trusted. Moving all bounds into the upgradeable contract would have removed exactly the
 *           check that makes an upgrade survivable.
 *        2. Every price is band-checked here too, against per-token floors and ceilings that a
 *           config transaction has to set explicitly.
 *        3. `UPGRADER_ROLE` is intended to be the timelocked multisig, separate from the
 *           `PRICE_ADMIN_ROLE` that manages day-to-day token configuration.
 *
 *      **Composition.** A Veda vault share is priced through its own base asset:
 *      `price(soUSD) = exchangeRate(soUSD->USDC) x price(USDC)`. This matters more than it first
 *      looks: soUSD's accountant is denominated in USDC (6 decimals, ~$1) while soETH's is
 *      denominated in WETH (18 decimals, ~$3000). A design that assumed the accountant's base was
 *      always dollars would misprice soETH by three orders of magnitude, so the base asset is always
 *      priced explicitly rather than assumed.
 *
 *      Composition is limited to **one hop** — a Veda token's base asset may not itself be a Veda
 *      token. That removes any possibility of a pricing cycle without needing recursion guards, and
 *      no real asset needs more.
 */
contract SolidPriceProvider is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ISolidPriceProvider
{
    using FixedPointMathLib for uint256;

    // ========================================= CONSTANTS =========================================

    /// @notice Decimals every price returned by this contract is quoted in.
    uint8 public constant PRICE_DECIMALS = 6;

    /// @notice One whole unit at `PRICE_DECIMALS`, i.e. exactly $1.00.
    uint256 public constant ONE_USD = 10 ** 6;

    /// @notice Manages per-token feed configuration.
    bytes32 public constant PRICE_ADMIN_ROLE = keccak256("PRICE_ADMIN_ROLE");

    /// @notice Authorises implementation upgrades. Intended to be a timelocked multisig.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ========================================= STORAGE =========================================

    mapping(address => PriceFeedConfig) internal _configs;

    /// @dev Enumeration for the lens and for ops review of the full configured set.
    address[] internal _configuredTokens;
    mapping(address => bool) internal _isConfigured;

    /**
     * @dev Reserved so future feed families can add storage without colliding with anything a
     *      subsequent contract in the inheritance chain might introduce.
     */
    uint256[45] private __gap;

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

    // ========================================= EVENTS =========================================

    event TokenConfigSet(address indexed token, PriceFeedKind kind, address source, address baseAsset);
    event TokenConfigRemoved(address indexed token);

    // ========================================= INITIALIZER =========================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin Receives `DEFAULT_ADMIN_ROLE`, `PRICE_ADMIN_ROLE` and `UPGRADER_ROLE`
     * @dev Roles are granted together for a clean bootstrap and are expected to be split immediately
     *      after deployment: day-to-day token configuration and the power to replace this
     *      implementation should not sit on the same key.
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

    /**
     * @inheritdoc ISolidPriceProvider
     * @dev Never reverts. Every failure mode - unconfigured token, paused accountant, stale rate,
     *      unusable base asset, price outside its band - collapses to `(0, false)` so an aggregating
     *      caller can attribute the failure to one token and still answer.
     */
    function priceUsd(address token) public view returns (uint256 price, bool usable) {
        PriceFeedConfig memory config = _configs[token];

        if (config.kind == PriceFeedKind.STABLE) {
            price = uint256(config.pegPriceUsd);
        } else if (config.kind == PriceFeedKind.VEDA_ACCOUNTANT) {
            (price, usable) = _priceVedaShare(config);
            if (!usable) return (0, false);
        } else {
            // NONE, or a kind written by a newer implementation than this one understands.
            return (0, false);
        }

        // The universal backstop: whatever the feed computed has to sit inside a band a human set.
        if (price < config.minPriceUsd || price > config.maxPriceUsd) return (0, false);

        return (price, true);
    }

    /**
     * @dev Prices a Veda / BoringVault share as `exchangeRate x price(baseAsset)`.
     *
     *      `exchangeRate` is quoted in base-asset units per one whole share, so dividing by the base
     *      asset's decimals - not the share's - is what makes this correct for both a 6-decimal
     *      USDC-based vault and an 18-decimal WETH-based one.
     *
     *      Mirrors ether.fi's `VedaAccountantPriceFeed`: refuse a paused accountant, refuse a rate
     *      older than `maxStaleness`, refuse a zero rate. The accountant enforces its own
     *      per-update deviation bounds and minimum update delay; none of it includes a liveness
     *      check, which is why staleness is enforced here.
     */
    function _priceVedaShare(PriceFeedConfig memory config) private view returns (uint256, bool) {
        (,,,, uint96 exchangeRate,,, uint64 lastUpdateTimestamp, bool accountantPaused,,,) =
            IAccountant(config.source).accountantState();

        if (accountantPaused) return (0, false);
        if (exchangeRate == 0) return (0, false);

        // Guard the subtraction: a future-dated timestamp would otherwise revert this view.
        uint256 age = block.timestamp > lastUpdateTimestamp ? block.timestamp - lastUpdateTimestamp : 0;
        if (age > config.maxStaleness) return (0, false);

        (uint256 basePrice, bool baseUsable) = priceUsd(config.baseAsset);
        if (!baseUsable) return (0, false);

        // One hop only (enforced in setTokenConfig), so this cannot recurse further.
        return (uint256(exchangeRate).mulDivDown(basePrice, 10 ** config.baseDecimals), true);
    }

    /**
     * @notice Converts a USD amount into token units at the current price, rounding up.
     * @dev Rounds up so a remainder can never leave the settlement destination short of the USD it is
     *      owed; the payer bears at most one token unit of rounding.
     * @param token Token to quote
     * @param amountUsd Amount in 6-decimal USD
     * @return tokenAmount Token units required
     * @return usable False when the token has no usable price, in which case `tokenAmount` is 0
     */
    function tokenAmountForUsd(address token, uint256 amountUsd)
        external
        view
        returns (uint256 tokenAmount, bool usable)
    {
        (uint256 price, bool priceUsable) = priceUsd(token);
        if (!priceUsable) return (0, false);

        return (amountUsd.mulDivUp(10 ** _configs[token].tokenDecimals, price), true);
    }

    /**
     * @notice Converts a token amount into its USD value at the current price, rounding down.
     * @param token Token to value
     * @param tokenAmount Amount in token units
     * @return amountUsd Value in 6-decimal USD
     * @return usable False when the token has no usable price
     */
    function usdValueOfToken(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 amountUsd, bool usable)
    {
        (uint256 price, bool priceUsable) = priceUsd(token);
        if (!priceUsable) return (0, false);

        return (tokenAmount.mulDivDown(price, 10 ** _configs[token].tokenDecimals), true);
    }

    // ========================================= CONFIGURATION =========================================

    /**
     * @notice Configures or replaces the feed for a token.
     * @dev Every cross-field relationship is validated here rather than trusted, because a
     *      misconfiguration is indistinguishable from a correct configuration at read time and would
     *      simply misprice the asset. In particular the accountant is checked to actually price this
     *      token (`vault() == token`) and to actually be denominated in the declared base asset
     *      (`base() == baseAsset`) - the two mistakes that would silently produce a wrong number.
     */
    function setTokenConfig(address token, PriceFeedConfig calldata config)
        external
        onlyRole(PRICE_ADMIN_ROLE)
    {
        if (token == address(0)) revert InvalidInput();
        if (config.minPriceUsd == 0 || config.maxPriceUsd < config.minPriceUsd) revert InvalidPriceBand();
        if (config.tokenDecimals != ERC20(token).decimals()) revert TokenDecimalsMismatch();

        if (config.kind == PriceFeedKind.STABLE) {
            if (config.pegPriceUsd < config.minPriceUsd || config.pegPriceUsd > config.maxPriceUsd) {
                revert PegPriceOutsideBand();
            }
        } else if (config.kind == PriceFeedKind.VEDA_ACCOUNTANT) {
            if (config.source == address(0) || config.maxStaleness == 0) revert InvalidInput();

            IAccountant accountant = IAccountant(config.source);
            if (accountant.vault() != token) revert AccountantVaultMismatch();
            if (accountant.base() != config.baseAsset) revert AccountantBaseMismatch();
            if (config.baseDecimals != ERC20(config.baseAsset).decimals()) revert TokenDecimalsMismatch();

            // The one-hop rule, enforced in both directions. Checking only that *my* base is not
            // composed is not enough: a token that is already serving as someone else's base could
            // later be converted into a composed feed, silently lengthening that chain. So a token
            // may be composed only if nothing is composed on top of it.
            //
            // Depth is what this bounds. A cycle is already impossible either way - closing one always
            // requires naming an already-composed token as a base, which is rejected - but an
            // unbounded chain would put N recursive calls on the authorize path's single read, where
            // the failure mode is a gas-exhausted decline rather than a wrong price.
            PriceFeedKind baseKind = _configs[config.baseAsset].kind;
            if (baseKind == PriceFeedKind.NONE) revert BaseAssetNotConfigured();
            if (baseKind == PriceFeedKind.VEDA_ACCOUNTANT) revert BaseAssetMustNotBeComposed();
            if (_isUsedAsBase(token)) revert TokenIsUsedAsABase();
        } else {
            revert UnsupportedFeedKind();
        }

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
     * @dev Linear in the configured set, which is small and only walked on configuration writes - never
     *      on the pricing path.
     */
    function isUsedAsBase(address token) external view returns (bool) {
        return _isUsedAsBase(token);
    }

    function _isUsedAsBase(address token) private view returns (bool) {
        uint256 length = _configuredTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            address other = _configuredTokens[i];
            if (
                other != token && _configs[other].kind == PriceFeedKind.VEDA_ACCOUNTANT
                    && _configs[other].baseAsset == token
            ) return true;
        }

        return false;
    }

    // ========================================= VIEWS =========================================

    /// @inheritdoc ISolidPriceProvider
    function getConfig(address token) external view returns (PriceFeedConfig memory) {
        return _configs[token];
    }

    /// @inheritdoc ISolidPriceProvider
    function configuredTokens() external view returns (address[] memory) {
        return _configuredTokens;
    }

    /**
     * @notice Prices several tokens in one call, for the authorize path and ops dashboards.
     */
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

    /**
     * @dev Restricted to `UPGRADER_ROLE`, intended to be the timelocked multisig and deliberately not
     *      the key that manages day-to-day token configuration. No zero-address check is needed:
     *      `ERC1967Utils` already rejects an implementation with no code.
     */
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
