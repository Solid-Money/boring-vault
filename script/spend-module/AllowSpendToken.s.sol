// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {console} from "forge-std/console.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";
import {PriceFeedConfig, PriceFeedKind} from "src/spend-module/interfaces/ISolidPriceProvider.sol";

import {SpendModuleConfig} from "./SpendModuleConfig.sol";

/**
 * @title AllowSpendToken
 * @notice Onboards an additional spendable asset: configures its feed on the provider, then
 *         allowlists it on the module.
 * @dev Both halves matter and the module does not connect them. `allowSpendToken` reads decimals from
 *      the token but never checks the provider even has a feed for it, so a token can be allowlisted
 *      while unpriceable - it then contributes 0 to quoted spending power and every `spend` touching
 *      it reverts with `PriceUnusable`. This script refuses that state.
 *
 *      The module band is what makes a hostile provider upgrade survivable, so it is required to be no
 *      wider than the provider's own band.
 *
 *      A composed (VEDA_ACCOUNTANT) asset needs its base asset already configured, and the base may
 *      not itself be composed - one hop only.
 *
 *      Env: TOKEN, MODULE_MIN_PRICE_USD, MODULE_MAX_PRICE_USD, HAIRCUT_BPS, and for the feed either
 *      PEG_PRICE_USD (stable) or ACCOUNTANT + BASE_ASSET + MAX_STALENESS (Veda share).
 *
 *        TOKEN=0x.. HAIRCUT_BPS=0 MODULE_MIN_PRICE_USD=900000 MODULE_MAX_PRICE_USD=3000000 \
 *        ACCOUNTANT=0x.. BASE_ASSET=0x.. MAX_STALENESS=604800 \
 *        forge script script/spend-module/AllowSpendToken.s.sol --rpc-url fuse --broadcast -vvv
 */
contract AllowSpendToken is SpendModuleConfig {
    function run() external {
        address token = vm.envAddress("TOKEN");
        uint16 haircutBps = uint16(vm.envUint("HAIRCUT_BPS"));
        uint96 moduleMin = uint96(vm.envUint("MODULE_MIN_PRICE_USD"));
        uint96 moduleMax = uint96(vm.envUint("MODULE_MAX_PRICE_USD"));

        requireHasCode(token, "token");
        require(moduleMin > 0 && moduleMax >= moduleMin, "invalid module price band");

        SolidPriceProvider provider =
            SolidPriceProvider(requireAddress("SolidPriceProvider", "DeploySpendModule.s.sol"));
        SolidCashModule module = SolidCashModule(requireAddress("SolidCashModule", "DeploySpendModule.s.sol"));

        uint8 decimals = ERC20(token).decimals();
        console.log("Token:   ", token);
        console.log("Decimals:", decimals);

        PriceFeedConfig memory existing = provider.getConfig(token);
        bool needsFeed = existing.kind == PriceFeedKind.NONE;

        vm.startBroadcast();

        if (needsFeed) {
            PriceFeedConfig memory feed = _buildFeed(decimals);

            // One hop only: a composed asset's base must already be configured and must not itself be
            // composed. `setTokenConfig` enforces this, but failing here names the problem.
            if (feed.kind == PriceFeedKind.VEDA_ACCOUNTANT) {
                PriceFeedKind baseKind = provider.getConfig(feed.baseAsset).kind;
                require(baseKind != PriceFeedKind.NONE, "base asset has no feed - configure it first");
                require(baseKind != PriceFeedKind.VEDA_ACCOUNTANT, "base asset is itself composed - one hop only");
            }

            provider.setTokenConfig(token, feed);
            console.log("Feed configured, kind:", uint256(feed.kind));
        } else {
            console.log("Feed already configured, kind:", uint256(existing.kind));
        }

        // Prove it prices before allowlisting. A token allowlisted while unpriceable is a silent
        // understatement of every holder's spending power.
        (uint256 price, bool usable) = provider.priceUsd(token);
        require(usable, "provider cannot price this token - refusing to allowlist");
        logUsd("Provider price", price);

        PriceFeedConfig memory feedNow = provider.getConfig(token);
        require(feedNow.tokenDecimals == decimals, "provider config decimals disagree with the token");
        require(
            moduleMin >= feedNow.minPriceUsd && moduleMax <= feedNow.maxPriceUsd,
            "module band must be no wider than the provider band"
        );

        module.allowSpendToken(token, haircutBps, moduleMin, moduleMax);

        vm.stopBroadcast();

        // Read back through the module, which is what `spend` actually uses.
        (uint256 modulePrice, bool moduleUsable) = module.getPriceUsd(token);
        require(moduleUsable, "module rejects the price after allowlisting - check the band");
        logUsd("Module price", modulePrice);

        console.log("Allowlisted. allowedTokens length:", module.allowedTokens().length);
        console.log("");
        console.log("Every allowlisted token is read on the lens' single authorize call, unguarded.");
        console.log("Re-run VerifySpendModule.s.sol to confirm availableToSpend still answers.");
        console.log("");
        console.log("Two follow-ups, neither of them on-chain:");
        console.log("  1. Add this token to spendTokens() in SpendModuleConfig.sol, or the next");
        console.log("     deploy and every verifier run will report an allowlist mismatch.");
        console.log("  2. Decide where it sits in the backend's draw order");
        console.log("     (DEFAULT_SPEND_TOKEN_PRIORITY / CASH_SPEND_TOKEN_PRIORITY in solid-backend).");
        console.log("     Left out, it is spendable but drawn LAST - after every named asset.");
    }

    /// @dev STABLE when PEG_PRICE_USD is set, otherwise VEDA_ACCOUNTANT from ACCOUNTANT/BASE_ASSET.
    function _buildFeed(uint8 decimals) private view returns (PriceFeedConfig memory) {
        uint256 peg = vm.envOr("PEG_PRICE_USD", uint256(0));
        uint96 feedMin = uint96(vm.envOr("FEED_MIN_PRICE_USD", vm.envUint("MODULE_MIN_PRICE_USD")));
        uint96 feedMax = uint96(vm.envOr("FEED_MAX_PRICE_USD", vm.envUint("MODULE_MAX_PRICE_USD")));

        if (peg > 0) {
            // A STABLE feed is a constant with no market input, so the provider's band can never
            // reject it. Only a manual reconfiguration responds to a depeg.
            console.log("WARNING: a STABLE feed is a fixed constant. A depeg is invisible on-chain;");
            console.log("         responding to one means a PRICE_ADMIN transaction.");
            return PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: decimals,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: uint96(peg),
                minPriceUsd: feedMin,
                maxPriceUsd: feedMax
            });
        }

        address accountant = vm.envAddress("ACCOUNTANT");
        address baseAsset = vm.envAddress("BASE_ASSET");
        uint64 maxStaleness = uint64(vm.envUint("MAX_STALENESS"));

        requireHasCode(accountant, "accountant");
        requireHasCode(baseAsset, "base asset");
        require(maxStaleness > 0, "MAX_STALENESS must be non-zero");

        // The base asset's decimals, not the share's - `exchangeRate` is quoted in base units, which
        // is what keeps this correct for a 6-decimal USDC vault and an 18-decimal WETH one alike.
        return PriceFeedConfig({
            kind: PriceFeedKind.VEDA_ACCOUNTANT,
            tokenDecimals: decimals,
            baseDecimals: ERC20(baseAsset).decimals(),
            maxStaleness: maxStaleness,
            source: accountant,
            baseAsset: baseAsset,
            pegPriceUsd: 0,
            minPriceUsd: feedMin,
            maxPriceUsd: feedMax
        });
    }
}
