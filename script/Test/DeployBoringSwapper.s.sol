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
    address constant boringVault    = 0xE003287E34fF16A109477e84A0D271C5c3dc3c7f;
    address constant rolesAuthority = 0x1Ae56c37aF9C27d036a1A8a4d9C0762e15D947B8;

    // 1inch FeeTaker we integrate with (fee-charged limit orders route output through it to the vault).
    address constant ONEINCH_FEE_TAKER = 0xc0DFdB9E7a392c3dBBE7c6FBe8FBC1789C9FE05e;
    // 1inch protocol/resolver fee receiver (from getFeeParams) — pinned in the adapter.
    address constant ONEINCH_PROTOCOL_FEE_RECEIVER = 0x90CbE4BDd538D6e9b379bFF5fE72c3d67A521De5;

    function setUp() external {
        setSourceChainName("mainnet");
        vm.createSelectFork("mainnet");
    }

    function run() external {
        vm.startBroadcast();

        // ---- Deploy a fresh full suite ----
        registry = new AdapterRegistry();
        console.log("AdapterRegistry:", address(registry));

        validator = new PriceValidator();
        console.log("PriceValidator: ", address(validator));

        // Fee registry owner = tx bundler so fee/recipient config routes through bundleTxs. maxFeeBps capped at 100%.
        FeeRegistry feeRegistry = new FeeRegistry(getAddress(sourceChain, "txBundlerAddress"), 10_000);
        console.log("FeeRegistry:    ", address(feeRegistry));

        // Swapper owner = tx bundler, so every requiresAuth setup call below routes through bundleTxs.
        BoringSwapper swapper = new BoringSwapper(
            getAddress(sourceChain, "txBundlerAddress"),
            registry,
            IFeeRegistry(address(feeRegistry)),
            BoringVault(payable(boringVault)),
            IPriceValidator(address(validator))
        );
        console.log("BoringSwapper:  ", address(swapper));

        // Deploy every adapter.
        address uniswapV3Adapter = address(new UniswapV3Adapter(getAddress(sourceChain, "uniV3Router")));
        address cowswapAdapter = address(new CowswapAdapter(
            getAddress(sourceChain, "cowswapSettlement"),
            getAddress(sourceChain, "cowswapVaultRelayer")
        ));
        address[] memory oneInchExecutors = new address[](1);
        oneInchExecutors[0] = getAddress(sourceChain, "oneInchExecutor");
        address oneInchAdapter = address(new OneInchAdapter(
            getAddress(sourceChain, "aggregationRouterV6"),
            ONEINCH_FEE_TAKER,
            ONEINCH_PROTOCOL_FEE_RECEIVER,
            oneInchExecutors,
            getAddress(sourceChain, "uniV2Factory"),
            getAddress(sourceChain, "uniV3Factory"),
            getAddress(sourceChain, "curveMetaRegistry")
        ));
        address openOceanAdapter = address(new OpenOceanAdapter(
            getAddress(sourceChain, "openOceanRouter"),
            getAddress(sourceChain, "openOceanCaller"),
            getAddress(sourceChain, "uniV2Factory"),
            getAddress(sourceChain, "uniV3Factory")
        ));
        address lifiAdapter = address(new LifiAdapter(getAddress(sourceChain, "lifi")));
        address m0Adapter = address(new M0Adapter(getAddress(sourceChain, "m0OrderBook")));

        console.log("UniswapV3Adapter:", uniswapV3Adapter);
        console.log("CowswapAdapter:  ", cowswapAdapter);
        console.log("OneInchAdapter:  ", oneInchAdapter);
        console.log("OpenOceanAdapter:", openOceanAdapter);
        console.log("LifiAdapter:     ", lifiAdapter);
        console.log("M0Adapter:       ", m0Adapter);

        // Register adapters (registry owner is the deployer EOA, so put() is a direct call).
        registry.put(uniswapV3Adapter, "UNISWAPV3_V1");
        registry.put(cowswapAdapter,   "COWSWAP_V1");
        registry.put(oneInchAdapter,   "ONEINCH_V1");
        registry.put(openOceanAdapter, "OPENOCEAN_V1");
        registry.put(lifiAdapter,      "LIFI_V1");
        registry.put(m0Adapter,        "M0_V1");

        // ---- Configure the swapper through the tx bundler (its owner) ----
        // Price WETH and USDC against the USDC quote asset, and set the USDC -> WETH route.
        address usdQuoteAsset = getAddress(sourceChain, "USDC");
        address[] memory usdRateProviders = new address[](1);
        usdRateProviders[0] = getAddress(sourceChain, "usdcUsdRateProvider");
        address[] memory ethRateProviders = new address[](1);
        ethRateProviders[0] = getAddress(sourceChain, "wethUsdRateProvider");

        Deployer.Tx[] memory txs = new Deployer.Tx[](12);
        txs[0] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSignature("setAuthority(address)", rolesAuthority), value: 0 });
        txs[1] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, uniswapV3Adapter, true), value: 0 });
        txs[2] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, cowswapAdapter,   true), value: 0 });
        txs[3] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, oneInchAdapter,   true), value: 0 });
        txs[4] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, openOceanAdapter, true), value: 0 });
        txs[5] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, lifiAdapter,      true), value: 0 });
        txs[6] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setApprovedAdapter.selector, m0Adapter,        true), value: 0 });
        txs[7] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setTokenOracle.selector, getERC20(sourceChain, "USDC"), usdQuoteAsset, _makeOracleConfig(usdRateProviders[0], address(0), false)), value: 0 });
        txs[8] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setTokenOracle.selector, getERC20(sourceChain, "WETH"), usdQuoteAsset, _makeOracleConfig(ethRateProviders[0], address(0), false)), value: 0 });
        txs[9] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setBaseAssetOracle.selector, getERC20(sourceChain, "USDC"), usdQuoteAsset, usdRateProviders), value: 0 });
        txs[10] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setBaseAssetOracle.selector, getERC20(sourceChain, "WETH"), usdQuoteAsset, ethRateProviders), value: 0 });
        // USDC -> WETH route: 10% (1000 bps) slippage cap, rate-limit capacity/refill normalized to 18 decimals.
        txs[11] = Deployer.Tx({ target: address(swapper), data: abi.encodeWithSelector(BoringSwapper.setRouteConfig.selector, getERC20(sourceChain, "USDC"), getERC20(sourceChain, "WETH"), 1000, 100_000_000e18, 100_000e18), value: 0 });

        Deployer(getAddress(sourceChain, "txBundlerAddress")).bundleTxs(txs);

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
