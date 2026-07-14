// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {MerkleTreeHelper} from "test/resources/MerkleTreeHelper/MerkleTreeHelper.sol";
import {BoringSwapper} from "src/base/Periphery/BoringSwapper.sol";
import {BoringVault} from "src/base/BoringVault.sol";
import {AdapterRegistry} from "src/base/Periphery/AdapterRegistry.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {IPriceValidator} from "src/interfaces/IPriceValidator.sol";
import {PriceValidator} from "src/base/Periphery/adapters/price/PriceValidator.sol";
import {UniswapV3Adapter} from "src/base/Periphery/adapters/UniswapV3Adapter.sol";
import {CowswapAdapter} from "src/base/Periphery/adapters/CowswapAdapter.sol";
import {OneInchAdapter} from "src/base/Periphery/adapters/OneInchAdapter.sol";
import {OneInchAdapterNoLimitOrdersNoExecutor} from "src/base/Periphery/adapters/OneInchAdapterNoLimitOrders.sol";
import {OpenOceanAdapter} from "src/base/Periphery/adapters/OpenOceanAdapter.sol";
import {LifiAdapter} from "src/base/Periphery/adapters/LifiAdapter.sol";
import {M0Adapter} from "src/base/Periphery/adapters/M0Adapter.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {Deployer} from "src/helper/Deployer.sol";
import {FeeRegistry} from "src/base/Periphery/FeeRegistry.sol";

import "forge-std/Script.sol";

/**
 *  source .env && forge script script/Test/DeployBoringSwapper.s.sol:DeployBoringSwapperTestSuite --broadcast --etherscan-api-key $ETHERSCAN_KEY --verify
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 *
 */
contract DeployBoringSwapperTestSuite is Script, MerkleTreeHelper {
    AdapterRegistry registry;
    PriceValidator validator;

    // Existing infra the freshly-deployed swapper serves.
    address constant boringVault = 0xC395ef909560FFAe6c3A6e5bf05827FDb1c34f9c; //swapper vault
    address constant rolesAuthority = 0x73Bd4c88066C013912018E8E31BE73b48c051bb3;

    function setUp() external {
        setSourceChainName("monad");
        vm.createSelectFork("monad");
    }

    function run() external {
        vm.startBroadcast();

        BoringSwapper swapper = BoringSwapper(0x6b01D470d3c2E57070E2DCC23a2576bAa4e49F9b);

        // ---- Deploy a fresh full suite ----
        //registry = new AdapterRegistry();
        //console.log("AdapterRegistry:", address(registry));

        //validator = new PriceValidator();
        //console.log("PriceValidator: ", address(validator));

        // Fee registry owner = tx bundler so fee/recipient config routes through bundleTxs. maxFeeBps capped at 100%.
        //FeeRegistry feeRegistry = new FeeRegistry(getAddress(sourceChain, "newDeployer"), 10_000);
        //console.log("FeeRegistry:    ", address(feeRegistry));

        // Swapper owner = tx bundler, so every requiresAuth setup call below routes through bundleTxs.
        //BoringSwapper swapper = new BoringSwapper(
        //    getAddress(sourceChain, "newDeployer"),
        //    registry,
        //    IFeeRegistry(address(feeRegistry)),
        //    BoringVault(payable(boringVault)),
        //    IPriceValidator(address(validator))
        //);
        //console.log("BoringSwapper:  ", address(swapper));

        // Deploy every adapter.
        //address uniswapV3Adapter = address(new UniswapV3Adapter(getAddress(sourceChain, "uniV3Router")));
        //address cowswapAdapter = address(new CowswapAdapter(
        //    getAddress(sourceChain, "cowswapSettlement"),
        //    getAddress(sourceChain, "cowswapVaultRelayer")
        //));
        //address[] memory oneInchExecutors = new address[](1);
        //oneInchExecutors[0] = getAddress(sourceChain, "oneInchExecutor");
        //address oneInchAdapter = address(new OneInchAdapter(
        //    getAddress(sourceChain, "aggregationRouterV6"),
        //    getAddress(sourceChain, "oneInchFeeTaker"),
        //    getAddress(sourceChain, "oneInchFeeReceiver"),
        //    oneInchExecutors,
        //    getAddress(sourceChain, "uniV2Factory"),
        //    getAddress(sourceChain, "uniV3Factory"),
        //    getAddress(sourceChain, "curveMetaRegistry")
        //));
        //address oneInchAdapterNoLimitOrdersNoExecutor = address(new OneInchAdapterNoLimitOrdersNoExecutor(
        //    getAddress(sourceChain, "aggregationRouterV6"),
        //    getAddress(sourceChain, "oneInchFeeTaker"),
        //    getAddress(sourceChain, "oneInchFeeReceiver"),
        //    getAddress(sourceChain, "uniV2Factory"),
        //    getAddress(sourceChain, "uniV3Factory"),
        //    getAddress(sourceChain, "curveMetaRegistry")
        //));
        //address openOceanAdapter = address(new OpenOceanAdapter(
        //    getAddress(sourceChain, "openOceanRouter"),
        //    getAddress(sourceChain, "openOceanCaller"),
        //    getAddress(sourceChain, "uniV2Factory"),
        //    getAddress(sourceChain, "uniV3Factory")
        //));
        //address lifiAdapter = address(new LifiAdapter(getAddress(sourceChain, "lifi")));
        //address m0Adapter = address(new M0Adapter(getAddress(sourceChain, "m0OrderBook")));

        //console.log("UniswapV3Adapter:", uniswapV3Adapter);
        //console.log("CowswapAdapter:  ", cowswapAdapter);
        //console.log("OneInchAdapter:  ", oneInchAdapter);
        //console.log("OneInchAdapterNoLimitOrdersNoExecutor:  ", oneInchAdapterNoLimitOrdersNoExecutor);
        //console.log("OpenOceanAdapter:", openOceanAdapter);
        //console.log("LifiAdapter:     ", lifiAdapter);
        //console.log("M0Adapter:       ", m0Adapter);

        // Register adapters (registry owner is the deployer EOA, so put() is a direct call).
        //registry.put(uniswapV3Adapter, "UNISWAPV3_V1");
        //registry.put(cowswapAdapter,   "COWSWAP_V1");
        //registry.put(oneInchAdapter,   "ONEINCH_V1");
        //registry.put(oneInchAdapterNoLimitOrdersNoExecutor,   "ONEINCH_NO_LIMITS_NO_EXECUTOR_V1");
        //registry.put(openOceanAdapter, "OPENOCEAN_V1");
        //registry.put(lifiAdapter,      "LIFI_V1");
        //registry.put(m0Adapter,        "M0_V1");

        // ---- Configure the swapper through the tx bundler (its owner) ----
        // Price WETH and USDC against the USDC quote asset, and set the USDC -> WETH route.
        //address usdQuoteAsset = getAddress(sourceChain, "USDC");
        //address[] memory usdRateProviders = new address[](1);
        //usdRateProviders[0] = getAddress(sourceChain, "usdcUsdRateProvider");
        //address[] memory ethRateProviders = new address[](1);
        //ethRateProviders[0] = getAddress(sourceChain, "wethUsdRateProvider");

        Deployer.Tx[] memory txs = new Deployer.Tx[](2);
        //txs[0] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSignature("setAuthority(address)", rolesAuthority), value: 0 });
        //txs[1] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, uniswapV3Adapter, true), value: 0 });
        //txs[2] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, cowswapAdapter,   true), value: 0 });
        //txs[3] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, oneInchAdapter,   true), value: 0 });
        //txs[4] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, oneInchAdapterNoLimitOrdersNoExecutor,   true), value: 0 });
        //txs[5] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, openOceanAdapter, true), value: 0 });
        //txs[1] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, lifiAdapter,      true), value: 0 });
        //txs[2] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, m0Adapter,        true), value: 0 });
        //txs[3] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setTokenOracle.selector, getERC20(sourceChain, "USDC"), usdQuoteAsset, _makeOracleConfig(usdRateProviders[0], address(0), false)), value: 0 });
        //txs[4] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setTokenOracle.selector, getERC20(sourceChain, "WETH"), usdQuoteAsset, _makeOracleConfig(ethRateProviders[0], address(0), false)), value: 0 });
        //txs[5] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setBaseAssetOracle.selector, getERC20(sourceChain, "USDC"), usdQuoteAsset, usdRateProviders), value: 0 });
        //txs[6] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setBaseAssetOracle.selector, getERC20(sourceChain, "WETH"), usdQuoteAsset, ethRateProviders), value: 0 });
        // USDC -> WETH route: 10% (1000 bps) slippage cap, rate-limit capacity/refill normalized to 18 decimals.
        //txs[7] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setRouteConfig.selector, getERC20(sourceChain, "USDC"), getERC20(sourceChain, "WETH"), 1000, 100_000_000e18, 100_000e18), value: 0 });
        // mUSD -> USDC route: 10% (1000 bps) slippage cap, rate-limit capacity/refill normalized to 18 decimals.
        txs[0] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setRouteConfig.selector, getERC20(sourceChain, "mUSD"), getERC20(sourceChain, "USDC"), 1000, 100_000_000e18, 100_000e18), value: 0 });
        // WMON -> mUSD route: 10% (1000 bps) slippage cap, rate-limit capacity/refill normalized to 18 decimals.
        txs[1] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setRouteConfig.selector, getERC20(sourceChain, "WMON"), getERC20(sourceChain, "mUSD"), 1000, 100_000_000e18, 100_000e18), value: 0 });

        Deployer(getAddress(sourceChain, "newDeployer")).bundleTxs(txs);

        vm.stopBroadcast();
    }

    function _makeOracleConfig(address rateProvider, address intermediary, bool skipValidation)
        internal
        pure
        returns (BoringSwapper.RateProviderConfig memory)
    {
        address[] memory rateProviders = new address[](1);
        rateProviders[0] = rateProvider;
        address[] memory intermediaries = new address[](1);
        intermediaries[0] = intermediary;
        return BoringSwapper.RateProviderConfig(rateProviders, intermediaries, skipValidation);
    }
}
