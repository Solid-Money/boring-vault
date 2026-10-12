// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {Params, TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";
import {PriceFeedConfigV2, PriceFeedKindV2} from "src/spend-module/v2/interfaces/ISolidPriceProviderV2.sol";

import {SpendModuleV2Config} from "../SpendModuleV2Config.sol";

/**
 * @title SpendModuleV2BaseConfig
 * @notice Parameters for the **Base** instance: dollar-denominated, EURC spendable.
 *
 * @dev Inherits the Fuse config for its record machinery and helpers only. **The token constants it
 *      carries are Fuse addresses and must never be used here** — Base has its own set below, and
 *      `spendTokens()` from the parent would allowlist Fuse addresses on Base. Everything this
 *      script family touches is prefixed `base`.
 *
 *      **The accounting unit is dollars, exactly as on Fuse.** EURC is not a peg here: in dollar
 *      terms it floats with EUR/USD at around 1.08, so it is priced as an ordinary market asset the
 *      same way soUSD is at around 1.07. Three consequences follow, and each is a place this is
 *      easy to get wrong:
 *
 *        1. Its provider entry is `EXTERNAL_ADAPTER`, **not** `STABLE_ADAPTER`. The latter returns
 *           `min(peg, observed)` and would cap EURC at a dollar, understating it by about 8% and
 *           over-collecting on every euro purchase.
 *        2. Its module price band must span normal EUR/USD movement. That makes the band a weak
 *           backstop rather than a real one, which is accepted deliberately: an out-of-band price
 *           sets `fullyPriced` false and freezes liquidation for the **whole position**, so a band
 *           tight enough to be meaningful would be a recurring outage. `setTokenPaused` is the lever
 *           that actually responds to a suspect EURC feed.
 *        3. `ceilingGrowthPerSec` is zero. The drifting ceiling only ever ratchets upward, which is
 *           right for a monotonically appreciating share and wrong for an exchange rate.
 *
 *      **Addresses are environment variables, not constants.** Every Base address this needs was
 *      unverified when these scripts were written, and a wrong address in a price path fails
 *      silently rather than loudly. Each accessor fails with the name to set.
 */
abstract contract SpendModuleV2BaseConfig is SpendModuleV2Config {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // ========================================= ADDRESSES =========================================

    /// @notice EURC on Base. Spendable, never collateral at launch.
    function baseEurc() internal view returns (address) {
        return _requireEnv("EURC_ADDRESS");
    }

    /// @notice Chainlink EURC/USD on Base. The numerator of EURC's quote, with no denominator.
    function baseEurcUsdFeed() internal view returns (address) {
        return _requireEnv("EURC_USD_FEED");
    }

    /**
     * @notice Chainlink's L2 sequencer uptime feed on Base.
     * @dev **Required, not optional.** While the sequencer is down every feed keeps returning its
     *      last answer with a recent timestamp, so a staleness bound catches nothing, and the moment
     *      it restarts those frozen prices become actionable. There is no correct value of this on
     *      an L2 other than the real feed.
     */
    function baseSequencerUptimeFeed() internal view returns (address) {
        return _requireEnv("SEQUENCER_UPTIME_FEED");
    }

    /**
     * @notice How long after the sequencer recovers before prices are trusted again.
     * @dev A real trade-off rather than a formality: too short and the first block after recovery
     *      prices off feeds that were frozen throughout the outage; too long and the card is dead
     *      after every blip. One hour is the common choice.
     */
    function baseSequencerGracePeriod() internal view returns (uint64) {
        return uint64(vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(1 hours)));
    }

    /**
     * @notice Heartbeat bound on the EURC/USD feed.
     * @dev Must match the feed's real heartbeat with margin. Too tight is a card outage every time
     *      the feed is slow; too loose and a dead feed prices a spend at yesterday's rate.
     */
    function baseEurcUsdMaxStaleness() internal view returns (uint64) {
        return uint64(vm.envOr("EURC_USD_MAX_STALENESS", uint256(24 hours)));
    }

    /**
     * @notice The `v1Module` immutable for a chain that has no v1.
     *
     * @dev Both `SolidCashModuleV2` and `SolidSpendLens` reject a zero address here, and Base has no
     *      legacy cohort. The check they perform is `ISafe(safe).isModuleEnabled(v1Module)`, so any
     *      address that is never enabled as a module on any Safe answers false forever, which is the
     *      behaviour a chain with no v1 wants.
     *
     *      The burn address is used rather than an arbitrary one because it is recognisable in a
     *      block explorer and provably nobody's contract. The cost is one wasted external call per
     *      spend on the authorize path, which is the price of not changing audited constructors for
     *      a deployment-shaped problem.
     */
    function baseV1Sentinel() internal view returns (address) {
        return vm.envOr("V1_MODULE_SENTINEL", address(0x000000000000000000000000000000000000dEaD));
    }

    // ========================================= EURC RISK =========================================

    /**
     * @dev Band on EURC in **dollars**, spanning normal EUR/USD movement with room.
     *
     *      Deliberately loose. EUR/USD has ranged well outside any band tight enough to be a real
     *      sanity check, and an out-of-band price freezes liquidation for every position holding the
     *      asset rather than just discounting that asset. A band that trips on ordinary currency
     *      movement would therefore be a recurring, system-wide outage.
     */
    uint64 internal constant EURC_MIN_PRICE_USD = 0.80e6;
    uint64 internal constant EURC_MAX_PRICE_USD = 1.50e6;

    /**
     * @dev The module's own staleness bound on EURC, independent of the provider's and of the
     *      adapter's. Three layers, because the provider is upgradeable and the adapter is
     *      replaceable while this one is baked into the module's configuration.
     */
    uint64 internal constant EURC_MAX_STALENESS = 1 days;

    /**
     * @notice EURC's module configuration: **spendable, never collateral.**
     *
     * @dev Collateral is withheld at launch for the same reason the Fuse stables are spend-only:
     *      lending against an asset whose dollar value moves with an exchange rate puts currency
     *      risk into every borrower's health factor, and that is a decision to take deliberately
     *      with its own risk parameters rather than as a side effect of making EURC spendable.
     *
     *      `ltv` and `liquidationThreshold` are therefore zero, which `validateTokenConfig` permits
     *      only while `collateral` is false — so promoting EURC later cannot happen by flipping one
     *      flag, and the flip is classified risk-increasing and waits out `paramChangeDelay`.
     */
    function baseEurcConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: false,
            tokenDecimals: 6,
            haircutBps: 0,
            liquidationBonusBps: 0,
            ltv: 0,
            liquidationThreshold: 0,
            maxStalenessSeconds: EURC_MAX_STALENESS,
            minPriceUsd: EURC_MIN_PRICE_USD,
            maxPriceUsd: EURC_MAX_PRICE_USD,
            // Zero, and not negotiable. The drifting ceiling only ratchets upward, which models a
            // monotonically appreciating share. An exchange rate is not one.
            ceilingGrowthPerSec: 0,
            ceilingAnchor: 0
        });
    }

    /**
     * @notice EURC's provider entry.
     * @dev `EXTERNAL_ADAPTER`, because in dollars EURC floats. `STABLE_ADAPTER` would cap it at a
     *      peg and over-collect on every euro purchase by roughly the euro premium.
     *
     *      The provider band is **tighter** than the module's, so the two are genuinely two layers.
     *      Identical bands were a standing finding against v1.
     */
    function baseEurcFeedConfig(address adapter) internal pure returns (PriceFeedConfigV2 memory) {
        return PriceFeedConfigV2({
            kind: PriceFeedKindV2.EXTERNAL_ADAPTER,
            tokenDecimals: 6,
            baseDecimals: 0,
            maxStaleness: EURC_MAX_STALENESS,
            source: adapter,
            baseAsset: address(0),
            pegPriceUsd: 0,
            minPriceUsd: 0.85e6,
            maxPriceUsd: 1.45e6,
            pairIndex: 0
        });
    }

    // ========================================= PARAMS =========================================

    /**
     * @notice Org parameters for the Base instance.
     * @dev Dollar-denominated, so the Fuse values carry over unchanged. Only the debit-relevant
     *      caps matter at launch, since Base ships with no collateral and therefore no credit: the
     *      credit numbers are set so the instance is coherent, not because anything can reach them.
     */
    function baseParams() internal pure returns (Params memory) {
        return Params({
            maxPerTxUsd: MAX_PER_TX_USD,
            maxDailyLimitUsd: MAX_DAILY_LIMIT_USD,
            maxMonthlyLimitUsd: MAX_MONTHLY_LIMIT_USD,
            defaultDailyLimitUsd: DEFAULT_DAILY_LIMIT_USD,
            defaultMonthlyLimitUsd: DEFAULT_MONTHLY_LIMIT_USD,
            maxDebtPerSafeUsd: MAX_DEBT_PER_SAFE_USD,
            // Zero would be the honest figure for a debit-only launch, but `_requireDebtCaps` reads
            // it as a cap rather than as a switch, so the first credit path enabled later would
            // revert until someone noticed. Left at the Fuse figure; no debt can exist while no
            // token is collateral.
            maxGlobalDebtUsd: MAX_GLOBAL_DEBT_USD,
            maxForcedSpendUsd: MAX_FORCED_SPEND_USD,
            dustFloorUsd: DUST_FLOOR_USD,
            minPositionUsd: MIN_POSITION_USD,
            targetLtvBps: TARGET_LTV_BPS,
            closeFactorBps: CLOSE_FACTOR_BPS,
            maxAdjustmentBps: MAX_ADJUSTMENT_BPS,
            modeDelay: MODE_DELAY,
            limitRaiseDelay: LIMIT_RAISE_DELAY,
            collateralWithdrawDelay: COLLATERAL_WITHDRAW_DELAY,
            liquidationGracePeriod: LIQUIDATION_GRACE_PERIOD,
            graceFloorHf: GRACE_FLOOR_HF,
            paramChangeDelay: PARAM_CHANGE_DELAY,
            limitWaiveDelay: LIMIT_WAIVE_DELAY
        });
    }

    // ========================================= HELPERS =========================================

    function requireBaseChain() internal view {
        require(block.chainid == BASE_CHAIN_ID, "these scripts target Base (8453) only");
    }

    function _requireEnv(string memory key) private view returns (address) {
        address value = vm.envOr(key, address(0));
        require(value != address(0), string.concat(key, " is required and was not set"));
        return value;
    }

    function logBaseInputs() internal view {
        console.log("EURC:                 ", baseEurc());
        console.log("EURC/USD feed:        ", baseEurcUsdFeed());
        console.log("Sequencer feed:       ", baseSequencerUptimeFeed());
        console.log("Sequencer grace (s):  ", baseSequencerGracePeriod());
        console.log("EURC/USD staleness:   ", baseEurcUsdMaxStaleness());
        console.log("v1 sentinel:          ", baseV1Sentinel(), "<-- no v1 on Base");
    }
}
