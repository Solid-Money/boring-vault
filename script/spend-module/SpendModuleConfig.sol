// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {PriceFeedConfig, PriceFeedKind} from "src/spend-module/interfaces/ISolidPriceProvider.sol";

/**
 * @title SpendModuleConfig
 * @notice Deployment parameters and the on-disk deployment record for the card spend module.
 * @dev Inherited by every script in this directory so there is one place a parameter is written and
 *      one place addresses are read from.
 *
 *      Numbers mirror `test/spend-module/SolidCashModuleFuseFork.t.sol`, which is the only
 *      configuration exercised against the live Fuse contracts.
 *
 *      Three assets are spendable: USDC, USDT and soUSD. USDC needed a feed regardless, because
 *      soUSD's accountant is denominated in it - what changed is that it (and USDT) are now
 *      *allowlisted* on the module rather than only priceable. The backend draws in that order
 *      (`DEFAULT_SPEND_TOKEN_PRIORITY` in solid-backend), so a card spend drains idle stables before
 *      it redeems any of the yield-bearing share. That ordering is deliberately off-chain: the module
 *      takes USD amounts per asset and converts each at the current price, so growing the asset set
 *      and retuning the draw order both stay possible without touching a non-upgradeable contract.
 *
 *      Addresses land in `deployments/addresses/<Network>/SpendModule.json`, the same file the
 *      Hardhat scripts in `scripts/spend-module/` use, so the two paths are interchangeable.
 */
abstract contract SpendModuleConfig is Script {
    // ========================================= EXTERNAL ADDRESSES (FUSE) =========================================

    /// @dev soUSD on Fuse - the LayerZero OFT share token users hold. Spendable, and drawn last.
    address internal constant SOUSD = 0x75333830E7014e909535389a6E5b0C02aA62ca27;

    /// @dev Accountant pricing soUSD, reached via the Fuse soUSD teller's `accountant()`. base = USDC.
    address internal constant SOUSD_ACCOUNTANT = 0x47A5e832E1178726dd13AdD762774A704878AD98;

    /// @dev USDC on Fuse (Stargate-bridged) - spendable, and soUSD's accountant base asset.
    address internal constant USDC = 0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9;

    /// @dev USDT on Fuse (Stargate-bridged) - spendable. Nothing else depends on its feed.
    address internal constant USDT = 0x3695Dd1D1D43B794C0B13eb8be8419Eb3ac22bf7;

    uint256 internal constant FUSE_CHAIN_ID = 122;

    // ========================================= ROLE IDS =========================================

    /// @dev May call `spend` and nothing else.
    uint8 internal constant SPENDER_ROLE = 1;

    /// @dev May call `pause` / `unpause` / `setSafePaused`. Deliberately not the spender.
    uint8 internal constant GUARDIAN_ROLE = 2;

    // ========================================= MODULE CONFIGURATION =========================================

    /**
     * @dev The multiple the app derives a monthly cap from a chosen daily one
     *      (`MONTHLY_LIMIT_MULTIPLIER` in solid-ui's `constants/cardSpendModule.ts`).
     *
     *      It has to be reflected here, because the app filters a daily preset out unless
     *      `daily * this <= maxMonthlyLimitUsd`. A monthly ceiling below the multiple of the daily
     *      one does not merely cap the month - it makes the top daily options *disappear from the
     *      picker*, with no error anywhere to explain why.
     */
    uint256 internal constant MONTHLY_LIMIT_MULTIPLIER = 10;

    /// @dev setOrgCaps. Live ceilings clamping every Safe on every read - the rollout throttle.
    uint256 internal constant MAX_DAILY_LIMIT_USD = 25_000e6;
    uint256 internal constant MAX_MONTHLY_LIMIT_USD = MAX_DAILY_LIMIT_USD * MONTHLY_LIMIT_MULTIPLIER;

    /**
     * @dev setOrgCaps' per-transaction cap, deliberately set *equal to* the daily ceiling so it can
     *      never be the binding constraint. `_maxCanSpendUsd` clamps every Safe's daily headroom to
     *      `MAX_DAILY_LIMIT_USD`, so any spend the rolling windows allow is already at or under this
     *      - which leaves the daily limit as the only cap a cardholder has to reason about.
     *
     *      Derived from the daily ceiling rather than written as its own number, so raising that
     *      ceiling cannot silently leave a per-transaction cap underneath it.
     *
     *      Never 0: the module's check is `totalUsd > maxPerTxUsd`, so 0 rejects every spend, while
     *      the backend's authorize path reads 0 as "no per-transaction cap" and would approve what
     *      the module then refuses.
     *
     *      Lowering this below the daily ceiling remains a live throttle if one is ever wanted; it
     *      just is not part of the normal configuration any more.
     */
    uint256 internal constant MAX_PER_TX_USD = MAX_DAILY_LIMIT_USD;

    /**
     * @dev setDefaultLimits. Applied when a Safe registers passing 0. Must not exceed the ceilings
     *      above, or every `registerSafe` reverts.
     *
     *      Equal to the ceilings, matching the app's activation default: a cardholder who never
     *      opens the limits sheet gets the full grant rather than a cap they would later hit at a
     *      till. Note what that means - one activation signature lets the module debit this much a
     *      day from that Safe. Lowering it is one owner transaction and immediate; a user lowering
     *      their own is `decreaseSpendingLimit`, also immediate.
     */
    uint256 internal constant DEFAULT_DAILY_LIMIT_USD = MAX_DAILY_LIMIT_USD;
    uint256 internal constant DEFAULT_MONTHLY_LIMIT_USD = MAX_MONTHLY_LIMIT_USD;

    /**
     * @dev setLimitRaiseDelay. The window in which an unintended increase can be cancelled.
     *
     *      One hour, not one day. The delay only ever gates *raises*, and it is paid by the Safes
     *      already registered under a lower cap: their stored limit is the binding one and no admin
     *      can lift it, so a user who outgrows it signs a raise and then cannot spend the new amount
     *      until this elapses. A day of that is a card that declines for a day. An hour still leaves
     *      a real window for a user (or Solid) to `cancelPendingSpendingLimitIncrease` on a raise
     *      nobody intended, which is the only thing the delay is for.
     */
    uint64 internal constant LIMIT_RAISE_DELAY = 1 hours;

    /// @dev setDustFloor. Quote-only reserve, so a quote cannot round up past what `spend` collects.
    uint256 internal constant DUST_FLOOR_USD = 0;

    /**
     * @dev allowSpendToken band for soUSD. This is the module's *own* band, checked independently of
     *      the upgradeable price provider - it is what makes a hostile or buggy provider upgrade
     *      survivable, so keep it as tight as the asset honestly allows.
     */
    uint96 internal constant SOUSD_MIN_PRICE_USD = 0.9e6;
    uint96 internal constant SOUSD_MAX_PRICE_USD = 3e6;

    /**
     * @dev Module band for the stablecoins, matching their provider band exactly.
     *
     *      Tighter than soUSD's for a reason that is not conservatism-for-its-own-sake: a STABLE feed
     *      is a hard-coded constant with no market input, so the provider's band can never reject it
     *      and the module's band is the ONLY place a depeg can be caught. A 3% window means a genuine
     *      depeg makes the asset unspendable (`PriceOutOfBounds`) instead of letting the module keep
     *      collecting 1.00 USD of value for every 0.90 USD of token.
     *
     *      Note what that costs when it fires: the asset stops contributing to spending power and
     *      every `spend` touching it reverts, so a depeg is an incident, not a graceful degradation.
     *      That is the right trade for a card - over-collecting a user's tokens is worse - but it is
     *      why `DEFAULT_SPEND_TOKEN_PRIORITY` has soUSD behind both stables rather than only USDC.
     */
    uint96 internal constant STABLE_MIN_PRICE_USD = 0.97e6;
    uint96 internal constant STABLE_MAX_PRICE_USD = 1.03e6;

    /**
     * @dev Quote-only valuation buffer. It makes `spendableUsd` more conservative and does NOT limit
     *      what `spend` collects, so 0 is right for a stablecoin and for a stable-denominated share
     *      alike; a volatile asset would need a real buffer here.
     */
    uint16 internal constant SOUSD_HAIRCUT_BPS = 0;
    uint16 internal constant STABLE_HAIRCUT_BPS = 0;

    /**
     * @dev Every asset the module allowlists at deploy, with its module-side band.
     *
     *      Order matters only in that it becomes `_allowedTokens` push order, which the lens returns
     *      `perTokenBreakdown` in - and which the backend deliberately does NOT treat as the draw
     *      order (see `DEFAULT_SPEND_TOKEN_PRIORITY`). It is listed cheapest-first anyway so the two
     *      agree by default.
     *
     *      Every entry must already have a feed from {@link priceFeeds}; `_configureCaps` checks that
     *      rather than trusting it, because a token allowlisted while unpriceable contributes zero to
     *      quoted spending power and reverts every `spend` that touches it.
     */
    struct SpendTokenParams {
        address token;
        uint16 haircutBps;
        uint96 minPriceUsd;
        uint96 maxPriceUsd;
        string label;
    }

    function spendTokens() internal pure returns (SpendTokenParams[] memory tokens) {
        tokens = new SpendTokenParams[](3);
        tokens[0] = SpendTokenParams(USDC, STABLE_HAIRCUT_BPS, STABLE_MIN_PRICE_USD, STABLE_MAX_PRICE_USD, "USDC");
        tokens[1] = SpendTokenParams(USDT, STABLE_HAIRCUT_BPS, STABLE_MIN_PRICE_USD, STABLE_MAX_PRICE_USD, "USDT");
        tokens[2] = SpendTokenParams(SOUSD, SOUSD_HAIRCUT_BPS, SOUSD_MIN_PRICE_USD, SOUSD_MAX_PRICE_USD, "soUSD");
    }

    // ========================================= KEYS =========================================

    /**
     * @notice Owns the module and the authority, and holds UPGRADER_ROLE on the provider.
     * @dev Timelocked multisig in production. Override with the OWNER env var.
     */
    function owner() internal view returns (address) {
        return vm.envOr("OWNER", 0x3B694d634981Ace4B64a27c48bffe19f1447779B);
    }

    /// @notice Backend sweep key (KMS in production). Gets SPENDER_ROLE.
    function spender() internal view returns (address) {
        return _requireEnvAddress("SPENDER");
    }

    /// @notice Pause key. Gets GUARDIAN_ROLE.
    function guardian() internal view returns (address) {
        return _requireEnvAddress("GUARDIAN");
    }

    /**
     * @notice The only address `spend` can ever send to.
     * @dev Immutable in the module. A wrong value means a redeploy *and* a re-consent transaction
     *      from every registered Safe, so this is required rather than defaulted.
     */
    function settlementTreasury() internal view returns (address) {
        return _requireEnvAddress("SETTLEMENT_TREASURY");
    }

    /**
     * @notice Holds PRICE_ADMIN_ROLE - day-to-day feed configuration.
     * @dev Should not be the same key as `owner`, which holds UPGRADER_ROLE: adjusting a feed and
     *      replacing the implementation over live user funds are different levels of authority.
     */
    function priceAdmin() internal view returns (address) {
        return vm.envOr("PRICE_ADMIN", owner());
    }

    /// @notice Reuse an existing FuseRolesAuthority instead of deploying a dedicated one.
    function existingAuthority() internal view returns (address) {
        return vm.envOr("EXISTING_AUTHORITY", address(0));
    }

    function _requireEnvAddress(string memory key) private view returns (address) {
        address value = vm.envOr(key, address(0));
        require(value != address(0), string.concat(key, " env var is required (see script/spend-module/README.md)"));
        return value;
    }

    // ========================================= PRICE FEEDS =========================================

    /**
     * @notice Feeds in configuration order.
     * @dev Order is load-bearing: a VEDA_ACCOUNTANT feed reverts with `BaseAssetNotConfigured` unless
     *      its base already has a feed, so bases come first.
     */
    function priceFeeds() internal pure returns (address[] memory tokens, PriceFeedConfig[] memory configs) {
        tokens = new address[](3);
        configs = new PriceFeedConfig[](3);

        // USDC as a hard peg. There is no market-price feed kind yet by design, which is why WETH -
        // and therefore soETH - cannot be onboarded until one is added by upgrade.
        tokens[0] = USDC;
        configs[0] = PriceFeedConfig({
            kind: PriceFeedKind.STABLE,
            tokenDecimals: 6,
            baseDecimals: 0,
            maxStaleness: 0,
            source: address(0),
            baseAsset: address(0),
            pegPriceUsd: 1e6,
            minPriceUsd: STABLE_MIN_PRICE_USD,
            maxPriceUsd: STABLE_MAX_PRICE_USD
        });

        // USDT, likewise a hard peg. WARNING, and it is the reason the module band above is 3% rather
        // than wide: a STABLE feed is a constant, so nothing on-chain observes a depeg. Responding to
        // one is a PRICE_ADMIN transaction (`setTokenConfig`) or an owner one (`updateSpendToken`),
        // and until it lands the module keeps valuing the token at exactly 1.00 USD.
        tokens[1] = USDT;
        configs[1] = PriceFeedConfig({
            kind: PriceFeedKind.STABLE,
            tokenDecimals: 6,
            baseDecimals: 0,
            maxStaleness: 0,
            source: address(0),
            baseAsset: address(0),
            pegPriceUsd: 1e6,
            minPriceUsd: STABLE_MIN_PRICE_USD,
            maxPriceUsd: STABLE_MAX_PRICE_USD
        });

        tokens[2] = SOUSD;
        configs[2] = PriceFeedConfig({
            kind: PriceFeedKind.VEDA_ACCOUNTANT,
            tokenDecimals: 6,
            // USDC's decimals, NOT soUSD's. `exchangeRate` is quoted in base-asset units, which is
            // what makes this correct for a 6-decimal USDC vault and an 18-decimal WETH one alike.
            baseDecimals: 6,
            // The live accountant enforces a ~1000s minimum update delay and +/-1% per update, so a
            // generous liveness window plus a wide absolute band is the right shape.
            maxStaleness: 7 days,
            source: SOUSD_ACCOUNTANT,
            baseAsset: USDC,
            pegPriceUsd: 0,
            minPriceUsd: 0.9e6,
            maxPriceUsd: 3e6
        });
    }

    // ========================================= DEPLOYMENT RECORD =========================================

    function _networkDir() private view returns (string memory) {
        if (block.chainid == FUSE_CHAIN_ID) return "Fuse";
        if (block.chainid == 1) return "Mainnet";
        if (block.chainid == 8453) return "Base";
        return vm.toString(block.chainid);
    }

    function deploymentPath() internal view returns (string memory) {
        return string.concat("deployments/addresses/", _networkDir(), "/SpendModule.json");
    }

    /// @dev Every key the record can hold. Kept explicit so the whole file is rewritten intact.
    function _recordKeys() private pure returns (string[6] memory) {
        return [
            "SolidPriceProvider",
            "SolidPriceProviderImplementation",
            "FuseRolesAuthority",
            "SolidCashModule",
            "SolidCashLens",
            "SettlementTreasury"
        ];
    }

    /**
     * @notice Records a deployed address so later scripts read it instead of it being pasted in.
     * @dev The whole record is re-serialized rather than patched, because `writeJson` with a value key
     *      cannot create a file that does not exist yet.
     *
     *      Skipped unless actually broadcasting, so a `--fork-url` rehearsal never overwrites the real
     *      record with fork addresses.
     */
    function saveAddress(string memory name, address value) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console.log(string.concat("  (dry run, not recorded) ", name), value);
            return;
        }

        string memory obj = "spendModuleRecord";
        string[6] memory keys = _recordKeys();
        string memory json;

        for (uint256 i = 0; i < keys.length; ++i) {
            bool isTarget = keccak256(bytes(keys[i])) == keccak256(bytes(name));
            address entry = isTarget ? value : readAddress(keys[i]);
            if (entry == address(0)) continue;

            // Each call adds to the object and returns the object's full JSON.
            json = vm.serializeAddress(obj, keys[i], entry);
        }

        require(bytes(json).length > 0, "nothing to record");

        // `writeFile` does not create parent directories, and this runs *after* broadcast - a failure
        // here would lose the addresses of contracts already deployed on-chain.
        vm.createDir(string.concat("deployments/addresses/", _networkDir()), true);

        // Wrapped by hand rather than with a cheatcode: `serializeJson` merges into an object instead
        // of nesting under a key, and the repo's records are shaped `{ contractAddresses: { .. } }`.
        vm.writeFile(
            deploymentPath(),
            string.concat(
                '{\n  "network": "',
                _networkDir(),
                '",\n  "chainId": ',
                vm.toString(block.chainid),
                ',\n  "contractAddresses": ',
                json,
                "\n}\n"
            )
        );
        console.log(string.concat("  recorded ", name), value);
    }

    /// @notice A previously deployed address, or `address(0)` when absent.
    function readAddress(string memory name) internal view returns (address) {
        string memory path = deploymentPath();
        if (!vm.exists(path)) return address(0);

        string memory json = vm.readFile(path);
        string memory key = string.concat(".contractAddresses.", name);
        if (!vm.keyExistsJson(json, key)) return address(0);

        return vm.parseJsonAddress(json, key);
    }

    /// @notice A previously deployed address, failing with the step that produces it.
    function requireAddress(string memory name, string memory producedBy) internal view returns (address) {
        address value = vm.envOr(name, readAddress(name));
        require(value != address(0), string.concat(name, " not found - run ", producedBy, " first"));
        return value;
    }

    function _keccak(string memory s) private pure returns (bytes32) {
        return keccak256(bytes(s));
    }

    // ========================================= HELPERS =========================================

    /// @dev Fails loudly rather than letting a later call decode empty returndata as a revert.
    function requireHasCode(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat(label, " has no code on this chain"));
    }

    /// @dev Logs a 6-decimal USD amount as `<label>: <whole>.<6dp> USD`.
    function logUsd(string memory label, uint256 amount) internal pure {
        uint256 fraction = amount % 1e6;
        string memory padded = vm.toString(fraction);
        // Left-pad the fractional part to six digits so 1_050_000 reads as 1.050000, not 1.50000.
        while (bytes(padded).length < 6) {
            padded = string.concat("0", padded);
        }
        console.log(string.concat(label, ": ", vm.toString(amount / 1e6), ".", padded, " USD"));
    }
}
