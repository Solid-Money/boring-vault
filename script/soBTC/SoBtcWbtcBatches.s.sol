// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Script.sol";
import {SoBtcConfig} from "./SoBtcConfig.sol";

/**
 * Builds the Safe batches that switch soBTC on Base from the cbBTC stack (0xb5Fb vault, never took
 * a deposit) to the WBTC stack, after DeploySoBtc, ConnectSoBtc and HandoverSoBtc have run on Base.
 * Nothing is broadcast: each batch is simulated on the chain (a fork, or live state) as its Safe,
 * its end state is checked, and the Safe Transaction Builder file is written.
 *
 *   SOBTC_BATCH=ethereum     forge script script/soBTC/SoBtcWbtcBatches.s.sol --rpc-url mainnet
 *   SOBTC_BATCH=base-switch  forge script script/soBTC/SoBtcWbtcBatches.s.sol --rpc-url base --evm-version prague
 *   SOBTC_BATCH=base-delist  forge script script/soBTC/SoBtcWbtcBatches.s.sol --rpc-url base --evm-version prague
 *
 * Order: ethereum and base-switch (any order) -> deploy the helm values that list the new soBTC on
 * the card -> base-delist. base-delist before the helm switch would revert every Base lens read.
 *
 *   ethereum (Safe 0x6B26): the Ethereum teller's Base peer -> the new Base teller (addChain
 *     overwrites the peer; the DVN config is per eid and stays), and the strategist's manage root
 *     (SOBTC_ETH_ROOT, optional).
 *   base-switch (Safe 0x5Eb1): the strategist's manage root on the new Base manager (SOBTC_BASE_ROOT);
 *     the new soBTC on the card (VEDA_ACCOUNTANT on the new accountant over Base WBTC, which the card
 *     already prices; the old soBTC's risk tier); the old cbBTC teller stops taking deposits and is
 *     unpeered from Ethereum.
 *   base-delist (Safe 0x5Eb1): the old soBTC off the card.
 */
contract SoBtcWbtcBatches is SoBtcConfig {
    // The retired Base stack (deployments/addresses/Base/soBTC.cbBTC-retired.json).
    address internal constant OLD_VAULT = 0xb5Fb6a807c1B35419CCC90480287305314D77B52;
    address internal constant OLD_ACCOUNTANT = 0x0C5BB76738BD2D095dBAb4a9Fe97D369284F9dD7;
    address internal constant OLD_TELLER = 0xBBd9100Be5712594B5db736e5280A4C0535Ee4Ec;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    // Base cash instance (core 0x47A5), as AddBaseSoBtcWbtc.
    address internal constant CORE = 0x47A5e832E1178726dd13AdD762774A704878AD98;
    address internal constant PROVIDER = 0x57b99807DFF5894be367889B98D82017DA9a441a;
    address internal constant BASE_WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    uint8 internal constant VEDA_ACCOUNTANT = 2;
    uint64 internal constant ACCOUNTANT_STALENESS = 7 days;
    uint96 internal constant PROVIDER_MIN = 5_000e6;
    uint96 internal constant PROVIDER_MAX = 1_000_000e6;
    uint64 internal constant MODULE_MIN = 2_000e6;
    uint64 internal constant MODULE_MAX = 2_000_000e6;

    struct Call {
        address to;
        bytes data;
    }

    Call[] internal calls;

    function run() external {
        string memory batch = vm.envString("SOBTC_BATCH");
        bytes32 b = keccak256(bytes(batch));
        if (b == keccak256("ethereum")) _ethereum();
        else if (b == keccak256("base-switch")) _baseSwitch();
        else if (b == keccak256("base-delist")) _baseDelist();
        else revert("SOBTC_BATCH: ethereum | base-switch | base-delist");
    }

    // ===================================== ETHEREUM =====================================

    function _ethereum() internal {
        BtcChain memory c = _chain();
        require(block.chainid == ETHEREUM_CHAIN_ID, "ethereum batch runs on Ethereum");
        string memory own = vm.readFile(c.record);
        string memory base = vm.readFile(c.peerRecord);
        require(vm.parseJsonAddress(base, ".asset") == BASE_WBTC, "Base record is not the WBTC stack");
        address teller = vm.parseJsonAddress(own, ".LayerZeroTeller");
        address manager = vm.parseJsonAddress(own, ".Manager");
        address baseTeller = vm.parseJsonAddress(base, ".LayerZeroTeller");
        require(baseTeller != OLD_TELLER, "Base record still holds the cbBTC teller");
        require(IOwned(teller).owner() == c.safe, "Ethereum teller is not the Safe's");

        calls.push(
            Call(
                teller,
                abi.encodeCall(ITellerChains.addChain, (BASE_EID, true, true, baseTeller, MESSAGE_GAS_LIMIT))
            )
        );
        bytes32 root = vm.envOr("SOBTC_ETH_ROOT", bytes32(0));
        if (root != bytes32(0)) calls.push(Call(manager, abi.encodeCall(IManager.setManageRoot, (STRATEGIST, root))));

        _simulate(c.safe);
        require(ITellerChains(teller).peers(BASE_EID) == bytes32(uint256(uint160(baseTeller))), "peer");
        (bool from, bool to, uint128 gas) = ITellerChains(teller).idToChains(BASE_EID);
        require(from && to && gas == MESSAGE_GAS_LIMIT, "chain flags");
        if (root != bytes32(0)) require(IManager(manager).manageRoot(STRATEGIST) == root, "root");
        _write(
            "deployments/safe-batches/eth-sobtc-base-wbtc.json",
            c.safe,
            "1",
            "Ethereum soBTC: Base peer -> WBTC stack",
            string.concat(
                "Ethereum teller addChain(30184 -> ",
                vm.toString(baseTeller),
                ")",
                root != bytes32(0) ? string.concat(" + strategist root ", vm.toString(root)) : "",
                "."
            )
        );
    }

    // ======================================= BASE =======================================

    address internal newVault;
    address internal newAccountant;
    address internal newManager;
    bytes32 internal baseRoot;

    function _baseSwitch() internal {
        BtcChain memory c = _chain();
        require(block.chainid == BASE_CHAIN_ID, "base batches run on Base");
        string memory rec = vm.readFile(c.record);
        newVault = vm.parseJsonAddress(rec, ".BoringVault");
        newAccountant = vm.parseJsonAddress(rec, ".Accountant");
        newManager = vm.parseJsonAddress(rec, ".Manager");
        baseRoot = vm.envBytes32("SOBTC_BASE_ROOT");
        _checkBaseSwitchInputs(c.safe);
        _pushBaseSwitch();
        _simulate(c.safe);
        _verifyBaseSwitch();
        _write(
            "deployments/safe-batches/base-sobtc-wbtc-switch.json",
            c.safe,
            "8453",
            "Base soBTC: WBTC stack live, cbBTC stack retired",
            _baseSwitchDescription()
        );
    }

    function _checkBaseSwitchInputs(address safe) internal view {
        require(newVault != OLD_VAULT, "Base record still holds the cbBTC vault");
        require(IAccountantView(newAccountant).vault() == newVault, "accountant vault");
        require(IAccountantView(newAccountant).base() == BASE_WBTC, "accountant base is not Base WBTC");
        require(IOwned(newManager).owner() == safe, "Run HandoverSoBtc on Base first");
        require(IERC20View(OLD_VAULT).totalSupply() == 0, "the cbBTC vault has shares");
        (, bool wbtcUsable) = IPriceProvider(PROVIDER).priceUsd(BASE_WBTC);
        require(wbtcUsable, "Base WBTC not priceable on the card provider");
        require(ICashSetters(CORE).getTokenConfig(newVault).tokenDecimals == 0, "new soBTC already allowlisted");
    }

    function _pushBaseSwitch() internal {
        calls.push(Call(newManager, abi.encodeCall(IManager.setManageRoot, (STRATEGIST, baseRoot))));
        PriceFeedConfigV2 memory feed = PriceFeedConfigV2({
            kind: VEDA_ACCOUNTANT,
            tokenDecimals: 8,
            baseDecimals: 8,
            maxStaleness: ACCOUNTANT_STALENESS,
            source: newAccountant,
            baseAsset: BASE_WBTC,
            pegPriceUsd: 0,
            minPriceUsd: PROVIDER_MIN,
            maxPriceUsd: PROVIDER_MAX,
            pairIndex: 0
        });
        calls.push(Call(PROVIDER, abi.encodeCall(IPriceProvider.setTokenConfig, (newVault, feed))));
        calls.push(Call(CORE, abi.encodeCall(ICashSetters.allowToken, (newVault, _soBtcTokenConfig()))));
        // The old stack: no more deposits, no more messages to or from Ethereum.
        calls.push(Call(OLD_TELLER, abi.encodeCall(ITellerChains.updateAssetData, (CBBTC, false, false, 0))));
        calls.push(Call(OLD_TELLER, abi.encodeCall(ITellerChains.removeChain, (ETHEREUM_EID))));
    }

    function _verifyBaseSwitch() internal view {
        require(IManager(newManager).manageRoot(STRATEGIST) == baseRoot, "root");
        (uint256 price, bool usable, bool inBand) = ICashCore(CORE).getPriceUsd(newVault);
        require(usable && inBand, "card cannot price the new soBTC");
        TokenConfig memory got = ICashSetters(CORE).getTokenConfig(newVault);
        require(got.spendable && got.collateral && got.ltv == _soBtcTokenConfig().ltv, "card config");
        require(!ICashCore(CORE).repayTender(newVault), "soBTC must not be repay tender");
        (bool dep, bool wd,) = ITellerChains(OLD_TELLER).assetData(CBBTC);
        require(!dep && !wd, "old teller still takes cbBTC");
        require(ITellerChains(OLD_TELLER).peers(ETHEREUM_EID) == bytes32(0), "old teller still peered");
        console.log("new soBTC on the card at $", price / 1e6);
    }

    function _baseSwitchDescription() internal view returns (string memory) {
        return string.concat(
            "Strategist root ",
            vm.toString(baseRoot),
            " on manager ",
            vm.toString(newManager),
            ". Card: soBTC ",
            vm.toString(newVault),
            " VEDA_ACCOUNTANT ",
            vm.toString(newAccountant),
            " x Base WBTC, 7d, LTV 60 / LT 70 / bonus 5% / haircut 2%. Old teller 0xBBd9: cbBTC deposits off, ",
            "Ethereum removed. Then deploy helm CASH_BASE_* with the new soBTC, then base-sobtc-cbbtc-delist."
        );
    }

    function _baseDelist() internal {
        BtcChain memory c = _chain();
        require(block.chainid == BASE_CHAIN_ID, "base batches run on Base");
        require(ICashSetters(CORE).getTokenConfig(OLD_VAULT).tokenDecimals != 0, "old soBTC not on the card");
        require(IERC20View(OLD_VAULT).totalSupply() == 0, "the cbBTC vault has shares");
        address vault = vm.parseJsonAddress(vm.readFile(c.record), ".BoringVault");
        require(ICashSetters(CORE).getTokenConfig(vault).tokenDecimals != 0, "run base-switch first");

        calls.push(Call(CORE, abi.encodeCall(ICashSetters.disallowToken, (OLD_VAULT))));
        _simulate(c.safe);
        require(ICashSetters(CORE).getTokenConfig(OLD_VAULT).tokenDecimals == 0, "old soBTC still allowlisted");
        _write(
            "deployments/safe-batches/base-sobtc-cbbtc-delist.json",
            c.safe,
            "8453",
            "Base card: delist the cbBTC soBTC",
            "disallowToken(0xb5Fb). Only after helm CASH_BASE_SPEND_TOKENS / CREDIT_COLLATERAL_PRIORITY list the new soBTC instead."
        );
    }

    function _soBtcTokenConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: true,
            tokenDecimals: 8,
            haircutBps: 200,
            liquidationBonusBps: 500,
            ltv: 0.6e18,
            liquidationThreshold: 0.7e18,
            maxStalenessSeconds: ACCOUNTANT_STALENESS,
            minPriceUsd: MODULE_MIN,
            maxPriceUsd: MODULE_MAX,
            ceilingGrowthPerSec: 0,
            ceilingAnchor: 0
        });
    }

    // ===================================== HELPERS =====================================

    function _simulate(address safe) internal {
        console.log("simulating %s calls as Safe %s", calls.length, safe);
        vm.startPrank(safe);
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                console.log("call %s reverted, target", i, calls[i].to);
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        vm.stopPrank();
    }

    function _write(
        string memory path,
        address safe,
        string memory chainId,
        string memory name,
        string memory description
    ) internal {
        // Fork rehearsals write next to their records, never over the real batches.
        string memory out = vm.envOr("SOBTC_BATCH_DIR", string(""));
        if (bytes(out).length != 0) path = string.concat(out, "/", _basename(path));
        string memory txs = "";
        for (uint256 i = 0; i < calls.length; ++i) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '\n    {"to": "',
                vm.toString(calls[i].to),
                '", "value": "0", "data": "',
                vm.toString(calls[i].data),
                '", "contractMethod": null, "contractInputsValues": null}'
            );
        }
        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": "',
            chainId,
            '",\n  "createdAt": ',
            vm.toString(block.timestamp * 1000),
            ',\n  "meta": {\n    "name": "',
            name,
            '",\n    "description": "',
            description,
            '",\n    "txBuilderVersion": "1.16.5",\n    "createdFromSafeAddress": "',
            vm.toString(safe),
            '"\n  },\n  "transactions": [',
            txs,
            "\n  ]\n}\n"
        );
        vm.writeFile(path, json);
        console.log("wrote %s (%s transactions)", path, calls.length);
    }

    function _basename(string memory path) internal pure returns (string memory) {
        bytes memory p = bytes(path);
        uint256 start;
        for (uint256 i = 0; i < p.length; ++i) {
            if (p[i] == "/") start = i + 1;
        }
        bytes memory out = new bytes(p.length - start);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = p[start + i];
        }
        return string(out);
    }
}

struct TokenConfig {
    bool spendable;
    bool collateral;
    uint8 tokenDecimals;
    uint16 haircutBps;
    uint16 liquidationBonusBps;
    uint64 ltv;
    uint64 liquidationThreshold;
    uint64 maxStalenessSeconds;
    uint64 minPriceUsd;
    uint64 maxPriceUsd;
    uint64 ceilingGrowthPerSec;
    uint64 ceilingAnchor;
}

struct PriceFeedConfigV2 {
    uint8 kind; // PriceFeedKindV2: 2 = VEDA_ACCOUNTANT
    uint8 tokenDecimals;
    uint8 baseDecimals;
    uint64 maxStaleness;
    address source;
    address baseAsset;
    uint96 pegPriceUsd;
    uint96 minPriceUsd;
    uint96 maxPriceUsd;
    uint32 pairIndex;
}

interface IOwned {
    function owner() external view returns (address);
}

interface IERC20View {
    function totalSupply() external view returns (uint256);
}

interface IAccountantView {
    function vault() external view returns (address);
    function base() external view returns (address);
}

interface IManager {
    function setManageRoot(address strategist, bytes32 root) external;
    function manageRoot(address strategist) external view returns (bytes32);
}

interface ITellerChains {
    function addChain(
        uint32 chainId,
        bool allowMessagesFrom,
        bool allowMessagesTo,
        address targetTeller,
        uint128 messageGasLimit
    ) external;
    function removeChain(uint32 chainId) external;
    function updateAssetData(address asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium) external;
    function assetData(address asset) external view returns (bool, bool, uint16);
    function peers(uint32 eid) external view returns (bytes32);
    function idToChains(uint32 eid) external view returns (bool, bool, uint128);
}

interface IPriceProvider {
    function setTokenConfig(address token, PriceFeedConfigV2 calldata config) external;
    function priceUsd(address token) external view returns (uint256, bool);
}

interface ICashSetters {
    function allowToken(address token, TokenConfig calldata config) external;
    function disallowToken(address token) external;
    function getTokenConfig(address token) external view returns (TokenConfig memory);
}

interface ICashCore {
    function getPriceUsd(address token) external view returns (uint256 price, bool usable, bool inBand);
    function repayTender(address token) external view returns (bool);
}
