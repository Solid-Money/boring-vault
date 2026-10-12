// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceAdapter} from "../interfaces/IPriceAdapter.sol";

/**
 * @notice The slice of a Chainlink aggregator this adapter reads.
 * @dev Declared locally rather than imported, exactly as `IAccountant` is, so the spend module
 *      carries no dependency on an oracle vendor's package.
 */
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title ChainlinkQuoteAdapter
 * @notice Prices a token as one Chainlink feed divided by another, in the consumer's own unit.
 *
 * @dev **One adapter, not one per asset.** Every feed a non-dollar book needs has the same shape: a
 *      quote against a base, both from Chainlink. Writing that once and configuring it per token is
 *      what keeps `setAdapterAllowed` meaningful, since each new allowlisted adapter address is a
 *      new thing the timelocked multisig has to vouch for.
 *
 *      Worked examples for a **euro-denominated** book on Base, which is the motivating case:
 *
 *      | Token | Numerator | Denominator | Result |
 *      |---|---|---|---|
 *      | EURC  | EURC/USD | EUR/USD | ~1.00 EUR, then capped at the peg by `STABLE_ADAPTER` |
 *      | USDC  | none     | EUR/USD | 1 / EURUSD, i.e. the dollar in euros |
 *      | WETH  | ETH/USD  | EUR/USD | ether in euros |
 *
 *      A dollar-denominated book uses the same contract with no denominator at all, in which case
 *      this is a plain passthrough with decimal normalisation.
 *
 *      `soEUR` and `soETH` are **not** configured here. They are `VEDA_ACCOUNTANT` entries on the
 *      provider, composed one hop on top of EURC and WETH respectively.
 *
 *      **The contract this must honour** is `IPriceAdapter`: six-decimal output in the consumer's
 *      unit, and never revert. The provider defends against a violation with a bounded staticcall
 *      and a returndata-length check, but an adapter that reverts makes every read of its token
 *      fail closed, so every path here returns `(0, false, 0)` instead of throwing.
 *
 *      **Sequencer awareness is not optional on an L2.** Base is a rollup, and while its sequencer
 *      is down every Chainlink feed keeps returning its last answer with an old timestamp. A
 *      staleness bound alone does not save you: the moment the sequencer restarts, feeds can be
 *      minutes stale while liquidations and spends are suddenly executable against prices nobody
 *      could act on during the outage. So this reads the L2 sequencer uptime feed first and refuses
 *      to price anything until a grace period after the sequencer comes back.
 *
 *      **Configuration is owner-only and deliberately not grantable.** Repointing a token's feeds is
 *      equivalent to setting its price, which is the same privilege as `setAdapterAllowed` on the
 *      provider, and that one sits with the timelocked multisig. Exposing it through `requiresAuth`
 *      would make it a property of the authority's table rather than of this contract, which is the
 *      mistake `setSettersImpl` documents.
 */
contract ChainlinkQuoteAdapter is Auth, IPriceAdapter {
    using Math for uint256;

    /// @notice Decimals every price this adapter returns is quoted in.
    uint8 public constant PRICE_DECIMALS = 6;

    /// @notice One whole unit at `PRICE_DECIMALS`.
    uint256 private constant PRICE_ONE = 10 ** 6;

    /// @notice Largest feed decimals accepted. Chainlink uses 8 for USD pairs and 18 for ETH pairs.
    uint8 private constant MAX_FEED_DECIMALS = 18;

    /**
     * @notice Gas forwarded to each feed read.
     * @dev Three reads at most per price call, so 150k against the provider's 200k budget for this
     *      adapter, leaving room for the arithmetic. A Chainlink `latestRoundData` is well under
     *      30k even cold. The cap exists so one misbehaving feed fails closed rather than consuming
     *      the authorize path's whole allowance.
     */
    uint256 private constant FEED_GAS_LIMIT = 50_000;

    /**
     * @notice Chainlink's L2 sequencer uptime feed, or zero to skip the check.
     * @dev Zero is only correct on an L1. On Base this must be set, and it is immutable because a
     *      deployment that could quietly drop the check is a deployment that will.
     */
    address public immutable sequencerUptimeFeed;

    /**
     * @notice How long after the sequencer recovers before prices are trusted again.
     * @dev Feeds do not all update the instant the sequencer restarts, so pricing immediately on
     *      recovery reads values that were fixed during the outage. Chainlink's own guidance is a
     *      grace period; an hour is the common choice.
     */
    uint64 public immutable sequencerGracePeriod;

    /**
     * @notice One token's composed quote.
     * @param numerator Feed for the numerator, or zero to use a constant 1
     * @param numeratorDecimals Cached at configuration time, never read on the hot path
     * @param numeratorMaxStaleness Per-leg, because an FX pair and an ETH pair have different
     *        heartbeats and a single bound would be wrong for one of them
     * @param configured Distinguishes a real entry from an empty slot, since both feeds may be zero
     *        individually
     */
    struct Quote {
        address numerator;
        uint8 numeratorDecimals;
        uint64 numeratorMaxStaleness;
        bool configured;
        address denominator;
        uint8 denominatorDecimals;
        uint64 denominatorMaxStaleness;
    }

    mapping(address token => Quote) internal _quotes;

    error InvalidInput();
    error Unauthorized();
    error FeedUnusable();
    error NotConfigured();

    event QuoteSet(
        address indexed token, address indexed numerator, address indexed denominator, uint256 probePrice
    );
    event QuoteRemoved(address indexed token);

    /**
     * @param _owner Timelocked multisig. The only address that may configure a quote.
     * @param _sequencerUptimeFeed Chainlink's L2 sequencer uptime feed for this chain. Required on
     *        Base; pass zero only on an L1, deliberately.
     * @param _sequencerGracePeriod Seconds after recovery before prices are trusted again.
     */
    constructor(address _owner, address _sequencerUptimeFeed, uint64 _sequencerGracePeriod)
        Auth(_owner, Authority(address(0)))
    {
        if (_owner == address(0)) revert InvalidInput();
        if (_sequencerUptimeFeed != address(0) && _sequencerGracePeriod == 0) revert InvalidInput();

        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
    }

    // ========================================= PRICING =========================================

    /**
     * @inheritdoc IPriceAdapter
     * @dev Never reverts. Unconfigured token, sequencer down or inside its grace period, a feed that
     *      reverts or returns short data or a non-positive answer, a stale leg, a zero denominator,
     *      or a composed price that rounds to zero all collapse to `(0, false, 0)`.
     *
     *      The reported timestamp is the **older** of the two legs, because a composed price is only
     *      as fresh as its stalest input. That is what lets the consumer apply its own staleness
     *      bound on top of the per-leg ones enforced here.
     */
    function price(address token) external view returns (uint256, bool, uint64) {
        Quote memory q = _quotes[token];
        if (!q.configured) return (0, false, 0);

        if (!_sequencerUp()) return (0, false, 0);

        uint256 numAnswer = 1;
        uint256 numScale = 1;
        uint64 numUpdatedAt = type(uint64).max;
        if (q.numerator != address(0)) {
            (uint256 a, uint64 t, bool ok) = _readFeed(q.numerator, q.numeratorMaxStaleness);
            if (!ok) return (0, false, 0);
            numAnswer = a;
            numScale = 10 ** q.numeratorDecimals;
            numUpdatedAt = t;
        }

        uint256 denAnswer = 1;
        uint256 denScale = 1;
        uint64 denUpdatedAt = type(uint64).max;
        if (q.denominator != address(0)) {
            (uint256 a, uint64 t, bool ok) = _readFeed(q.denominator, q.denominatorMaxStaleness);
            if (!ok) return (0, false, 0);
            denAnswer = a;
            denScale = 10 ** q.denominatorDecimals;
            denUpdatedAt = t;
        }

        // price = (num / numScale) / (den / denScale) * 10^6, rearranged to divide exactly once.
        uint256 scaledNumerator = numAnswer * denScale;
        uint256 scaledDenominator = denAnswer * numScale;
        if (scaledDenominator == 0) return (0, false, 0);

        uint256 composed = scaledNumerator.mulDiv(PRICE_ONE, scaledDenominator, Math.Rounding.Floor);
        if (composed == 0) return (0, false, 0);

        uint64 updatedAt = numUpdatedAt < denUpdatedAt ? numUpdatedAt : denUpdatedAt;

        return (composed, true, updatedAt);
    }

    /**
     * @dev Whether the L2 sequencer is up and has been for longer than the grace period.
     *
     *      Chainlink's uptime feed answers 0 for up and 1 for down, and `startedAt` is when the
     *      current status began. A `startedAt` of zero means the round has not been initialised,
     *      which is treated as down rather than as up.
     */
    function _sequencerUp() private view returns (bool) {
        if (sequencerUptimeFeed == address(0)) return true;

        (bool success, bytes memory ret) = sequencerUptimeFeed.staticcall{gas: FEED_GAS_LIMIT}(
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector)
        );
        if (!success || ret.length != 160) return false;

        (, int256 answer, uint256 startedAt,,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));

        if (answer != 0) return false;
        if (startedAt == 0) return false;
        if (block.timestamp < startedAt) return false;

        return block.timestamp - startedAt > sequencerGracePeriod;
    }

    /**
     * @dev One feed read, bounded and failure-tolerant.
     *
     *      A raw `staticcall` rather than a typed call, for the two reasons the provider gives for
     *      its own: a high-level call forwards all remaining gas, and it does not catch a failure to
     *      *decode* the return data, so an address with no code succeeds, returns nothing, and
     *      propagates a decode revert past any `catch`.
     */
    function _readFeed(address feed, uint64 maxStaleness)
        private
        view
        returns (uint256 answer, uint64 updatedAt, bool ok)
    {
        (bool success, bytes memory ret) =
            feed.staticcall{gas: FEED_GAS_LIMIT}(abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector));
        // `latestRoundData` returns five static values, i.e. exactly five words.
        if (!success || ret.length != 160) return (0, 0, false);

        (, int256 rawAnswer,, uint256 rawUpdatedAt,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));

        if (rawAnswer <= 0) return (0, 0, false);
        if (rawUpdatedAt == 0 || rawUpdatedAt > type(uint64).max) return (0, 0, false);

        // Guarded, so a future-dated round cannot revert this view.
        uint256 age = block.timestamp > rawUpdatedAt ? block.timestamp - rawUpdatedAt : 0;
        if (maxStaleness != 0 && age > maxStaleness) return (0, 0, false);

        return (uint256(rawAnswer), uint64(rawUpdatedAt), true);
    }

    // ========================================= CONFIGURATION =========================================

    /**
     * @notice Configures the composed quote for one token. **Owner only, never grantable.**
     * @dev Feed decimals are read once here and cached, so the hot path makes no `decimals()` call
     *      and has one less way to fail.
     *
     *      The quote is probed before it is stored, exactly as the provider probes an adapter before
     *      letting a token depend on one. A configuration that cannot price its own token is a
     *      misconfiguration that would otherwise only surface as a declined card transaction.
     *
     *      At least one leg must be a real feed. Two zero legs would be a constant 1.00, which is a
     *      bare peg with nothing observing it, and this contract exists precisely so that a price
     *      has something behind it.
     * @param token The token to price
     * @param numerator Feed for the numerator, or zero for a constant 1
     * @param numeratorMaxStaleness Heartbeat bound for the numerator leg. Zero disables the check
     * @param denominator Feed for the denominator, or zero for a constant 1
     * @param denominatorMaxStaleness Heartbeat bound for the denominator leg
     */
    function setQuote(
        address token,
        address numerator,
        uint64 numeratorMaxStaleness,
        address denominator,
        uint64 denominatorMaxStaleness
    ) external {
        _requireOwner();
        if (token == address(0)) revert InvalidInput();
        if (numerator == address(0) && denominator == address(0)) revert InvalidInput();
        if (numerator != address(0) && numeratorMaxStaleness == 0) revert InvalidInput();
        if (denominator != address(0) && denominatorMaxStaleness == 0) revert InvalidInput();

        Quote memory q = Quote({
            numerator: numerator,
            numeratorDecimals: numerator == address(0) ? 0 : _feedDecimals(numerator),
            numeratorMaxStaleness: numeratorMaxStaleness,
            configured: true,
            denominator: denominator,
            denominatorDecimals: denominator == address(0) ? 0 : _feedDecimals(denominator),
            denominatorMaxStaleness: denominatorMaxStaleness
        });

        _quotes[token] = q;

        // Prove it answers before anything depends on it. Reverting here is correct: this is a
        // configuration call, not the hot path, and the never-revert contract binds `price` alone.
        (uint256 probe, bool ok,) = this.price(token);
        if (!ok || probe == 0) {
            delete _quotes[token];
            revert FeedUnusable();
        }

        emit QuoteSet(token, numerator, denominator, probe);
    }

    /// @notice Removes a token's quote, making it unpriceable. **Owner only.**
    /// @dev Fail-closed by construction: the provider reports the token unusable, so it stops
    ///      contributing to spending power and to borrowing power rather than being mispriced.
    function removeQuote(address token) external {
        _requireOwner();
        if (!_quotes[token].configured) revert NotConfigured();

        delete _quotes[token];
        emit QuoteRemoved(token);
    }

    /// @notice The stored quote for a token.
    function getQuote(address token) external view returns (Quote memory) {
        return _quotes[token];
    }

    /// @dev Reads and validates a feed's decimals at configuration time.
    function _feedDecimals(address feed) private view returns (uint8) {
        (bool success, bytes memory ret) =
            feed.staticcall{gas: FEED_GAS_LIMIT}(abi.encodeWithSelector(IAggregatorV3.decimals.selector));
        if (!success || ret.length != 32) revert FeedUnusable();

        uint256 decimals = abi.decode(ret, (uint256));
        if (decimals == 0 || decimals > MAX_FEED_DECIMALS) revert InvalidInput();

        return uint8(decimals);
    }

    /// @dev Owner directly, bypassing the authority. Repointing a feed is equivalent to setting a
    ///      price, so it must not be a capability any role can be granted.
    function _requireOwner() private view {
        if (msg.sender != owner) revert Unauthorized();
    }

    // ========================================= AUTH OVERRIDES =========================================

    /// @notice Owner only, never grantable. Same reasoning as `SolidCashStorageV2`'s override.
    function transferOwnership(address newOwner) public override {
        _requireOwner();
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }

    /// @notice Permanently disabled. This contract answers to its owner and to nothing else, so an
    ///         authority would only ever widen who can set prices.
    function setAuthority(Authority) public pure override {
        revert Unauthorized();
    }
}
