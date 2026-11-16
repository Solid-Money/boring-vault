// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Script.sol";

/**
 * soBTC: addresses and parameters shared by the deploy, connect and handover scripts.
 *
 * Two BoringVault stacks, one on Ethereum and one on Base, peered over LayerZero. WBTC on both:
 *   - Ethereum: WBTC deposits (depositAndBridge sends the shares to Base), WBTC withdraw queue, the
 *     strategies.
 *   - Base:     WBTC deposits (Base WBTC is BitGo's LayerZero OFT 0x0555), shares stay on Base. No
 *     withdrawals and no queue: the strategist bridges the WBTC to the Ethereum vault (OFT send), and
 *     a user withdraws by bridging shares Base -> Ethereum, then queueing there.
 * Both accountants carry the same rate, pushed by the backend.
 *
 * Nov 16 2026: Base was redeployed with WBTC. The first Base stack (cbBTC, 0xb5Fb vault) never
 * took a deposit; its record is deployments/addresses/Base/soBTC.cbBTC-retired.json.
 *
 * Everything not specific to BTC is copied from soETH (Ethereum + Base), read on 2026-11-13.
 */
abstract contract SoBtcConfig is Script {
    // ── Chains ──────────────────────────────────────────────────────────────
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint32 internal constant ETHEREUM_EID = 30101;
    uint32 internal constant BASE_EID = 30184;

    // Same address on both chains.
    address internal constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // The deployer owns everything until HandoverSoBtc hands it to the chain's Safe.
    address internal constant DEPLOYER = 0x3B694d634981Ace4B64a27c48bffe19f1447779B;

    // ── Vault ───────────────────────────────────────────────────────────────
    string internal constant NAME = "Solid BTC";
    string internal constant SYMBOL = "soBTC";
    // Equal on both chains (LayerZero moves raw share amounts), and equal to WBTC/cbBTC, so the
    // rate is 1e8 at launch.
    uint8 internal constant DECIMALS = 8;
    uint96 internal constant START_RATE = 1e8;

    // ── Accountant: as soETH ────────────────────────────────────────────────
    address internal constant PAYOUT = DEPLOYER; // as both soETH accountants; the Safe can change it
    uint16 internal constant RATE_CHANGE_UPPER = 10100;
    uint16 internal constant RATE_CHANGE_LOWER = 9900;
    uint24 internal constant MIN_UPDATE_DELAY = 1000;
    uint16 internal constant PLATFORM_FEE = 0;
    uint16 internal constant PERFORMANCE_FEE = 1000;

    // ── Actors: the backend keys that hold these roles on every soETH authority ──
    address internal constant STRATEGIST = 0x6f3334EC6355eD6f70100Cd1Cd6736505cd0F9b5; // STRATEGIST (7)
    address internal constant RATE_UPDATER = 0xBE7cDa9d1F046e90A898d01F686f4176b0d8b33F; // UPDATE_EXCHANGE_RATE (11)

    // ── Solver Safes ────────────────────────────────────────────────────────
    // Each vault gets its own solver Safe on each chain. Created by DeploySoBtc through the Safe
    // 1.5.0 factory, with the owners and threshold of the soETH solver Safes (Ethereum 0xA7Fd,
    // Base 0xdBa5): 2-of-5.
    address internal constant SAFE_FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b; // SafeProxyFactory 1.5.0
    address internal constant SAFE_L2_SINGLETON = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e; // SafeL2 1.5.0
    address internal constant SAFE_FALLBACK = 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4; // CompatibilityFallbackHandler 1.5.0
    uint256 internal constant SOLVER_SAFE_THRESHOLD = 2;

    function _solverSafeOwners() internal pure returns (address[] memory o) {
        o = new address[](5);
        o[0] = 0x3B694d634981Ace4B64a27c48bffe19f1447779B;
        o[1] = 0x2B30BD61C63DA8E528935A8589866D0509c39a50;
        o[2] = 0x26F9A59F0F0e92e8a8d6f835d57657a3a3b51103;
        o[3] = 0x6A7469b0da4c071450b2e400891B43421Bb4f36E;
        o[4] = 0x63A61a31F087295a2b3fbE6F546913Ccbe8127e8;
    }

    // ── Queue: as soETH, except the minimum (8-decimal shares) ──────────────
    bool internal constant TRACK_WITHDRAWS_ON_CHAIN = true;
    bool internal constant EXCESS_TO_SOLVER_NON_SELF_SOLVE = true;
    uint24 internal constant SECONDS_TO_MATURITY = 120;
    uint24 internal constant MINIMUM_SECONDS_TO_DEADLINE = 259_200; // 3 days
    uint16 internal constant MIN_DISCOUNT = 1;
    uint16 internal constant MAX_DISCOUNT = 100;
    uint96 internal constant MINIMUM_SHARES = 1_000; // 0.00001 soBTC

    // ── Roles and selectors, as on the soETH authorities ────────────────────
    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant MINTER_ROLE = 2;
    uint8 internal constant BURNER_ROLE = 3;
    uint8 internal constant STRATEGIST_ROLE = 7;
    uint8 internal constant UPDATE_EXCHANGE_RATE_ROLE = 11;
    uint8 internal constant SOLVER_ROLE = 12;
    uint8 internal constant CAN_SOLVE_ROLE = 31;
    uint8 internal constant ONLY_QUEUE_ROLE = 32;
    uint8 internal constant SOLVER_ORIGIN_ROLE = 33;
    uint8 internal constant BULK_WITHDRAW_ROLE = 36;

    bytes4 internal constant VAULT_MANAGE = 0xf6e715d0; // manage(address,bytes,uint256)
    bytes4 internal constant VAULT_ENTER = 0x39d6ba32; // enter(...)
    bytes4 internal constant VAULT_EXIT = 0x18457e61; // exit(...)
    bytes4 internal constant ACCOUNTANT_UPDATE_RATE = 0x3458113d; // updateExchangeRate(uint96)
    bytes4 internal constant MANAGER_MANAGE_MERKLE = 0x244b0f6a; // manageVaultWithMerkleVerification(...)
    bytes4 internal constant TELLER_DEPOSIT = 0x0efe6a8b; // deposit(address,uint256,uint256), public
    bytes4 internal constant TELLER_DEPOSIT_AND_BRIDGE = 0xcab716e8; // depositAndBridge(...), public on Ethereum
    bytes4 internal constant TELLER_BRIDGE = 0x05921740; // bridge(uint96,address,bytes,address,uint256), public
    bytes4 internal constant TELLER_BULK_WITHDRAW = 0x3e64ce99; // bulkWithdraw(address,uint256,uint256,address)
    bytes4 internal constant QUEUE_SOLVE = 0x412638dc; // solveOnChainWithdraws(...)
    bytes4 internal constant QUEUE_CANCEL_USER_WITHDRAWS = 0x9fff7e2a; // cancelUserWithdraws(...)
    bytes4 internal constant QUEUE_REQUEST = 0x6bb3b476; // requestOnChainWithdraw(...), public
    bytes4 internal constant QUEUE_CANCEL_BY_ID = 0x08bf866e; // cancelOnChainWithdrawUsingRequestId(bytes32), public
    bytes4 internal constant SOLVER_REDEEM_SOLVE = 0x5ff8a71f; // boringRedeemSolve(...)
    bytes4 internal constant SOLVER_BORING_SOLVE = 0x67aa0416; // boringSolve(...), queue callback

    // ── LayerZero: as the live soETH Ethereum <-> Base pathway ──────────────
    uint128 internal constant MESSAGE_GAS_LIMIT = 300_000;
    uint64 internal constant CONF_BASE_TO_ETHEREUM = 10;
    uint64 internal constant CONF_ETHEREUM_TO_BASE = 15;
    uint32 internal constant MAX_MESSAGE_SIZE = 10_000;
    uint32 internal constant EXECUTOR_CONFIG_TYPE = 1;
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    string internal constant ETHEREUM_RECORD = "deployments/addresses/Mainnet/soBTC.json";
    string internal constant BASE_RECORD = "deployments/addresses/Base/soBTC.json";

    // Everything that differs between the two chains.
    struct BtcChain {
        string name;
        uint32 eid;
        uint32 peerEid;
        address safe; // owner of every soBTC contract on this chain after the handover
        address asset; // deposit and base asset, and the withdraw asset where there are withdrawals
        address weth; // the teller's native wrapper (native deposits are never enabled)
        bool depositAndBridge; // public on Ethereum only: WBTC deposits mint on Base
        bool withdrawals; // Ethereum only: withdraw queue, solver and solver Safe; Base has none
        uint64 confSend;
        uint64 confReceive;
        address sendLib;
        address receiveLib;
        address executor;
        address dvnLow; // required DVNs, sorted ascending: LayerZero Labs + Nethermind
        address dvnHigh;
        string record;
        string peerRecord;
    }

    function _chain() internal view returns (BtcChain memory c) {
        if (block.chainid == ETHEREUM_CHAIN_ID) {
            c = BtcChain({
                name: "Ethereum",
                eid: ETHEREUM_EID,
                peerEid: BASE_EID,
                safe: 0x6B26fAF3AD822695127B29ad242ac4B33D336F42, // owns soETH on Ethereum
                asset: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // WBTC
                weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                depositAndBridge: true,
                withdrawals: true,
                confSend: CONF_ETHEREUM_TO_BASE,
                confReceive: CONF_BASE_TO_ETHEREUM,
                sendLib: 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1,
                receiveLib: 0xc02Ab410f0734EFa3F14628780e6e695156024C2,
                executor: 0x173272739Bd7Aa6e4e214714048a9fE699453059,
                dvnLow: 0x589dEDbD617e0CBcB916A9223F4d1300c294236b,
                dvnHigh: 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5,
                record: _envRecord("SOBTC_ETHEREUM_RECORD", ETHEREUM_RECORD),
                peerRecord: _envRecord("SOBTC_BASE_RECORD", BASE_RECORD)
            });
        } else if (block.chainid == BASE_CHAIN_ID) {
            c = BtcChain({
                name: "Base",
                eid: BASE_EID,
                peerEid: ETHEREUM_EID,
                safe: 0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3, // owns soUSD/soEUR/soETH on Base
                asset: 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c, // WBTC (LayerZero OFT)
                weth: 0x4200000000000000000000000000000000000006,
                depositAndBridge: false,
                withdrawals: false,
                confSend: CONF_BASE_TO_ETHEREUM,
                confReceive: CONF_ETHEREUM_TO_BASE,
                sendLib: 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2,
                receiveLib: 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf,
                executor: 0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4,
                dvnLow: 0x9e059a54699a285714207b43B055483E78FAac25,
                dvnHigh: 0xcd37CA043f8479064e10635020c65FfC005d36f6,
                record: _envRecord("SOBTC_BASE_RECORD", BASE_RECORD),
                peerRecord: _envRecord("SOBTC_ETHEREUM_RECORD", ETHEREUM_RECORD)
            });
        } else {
            revert("Run on Ethereum or Base");
        }
    }

    // Dry runs and fork rehearsals point the records at .dryrun/ so they never touch the real ones.
    function _envRecord(string memory key, string memory fallback_) internal view returns (string memory) {
        return vm.envOr(key, fallback_);
    }

    struct SetConfigParam {
        uint32 eid;
        uint32 configType;
        bytes config;
    }

    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    struct ExecutorConfig {
        uint32 maxMessageSize;
        address executor;
    }

    function _uln(uint32 eid, uint64 confirmations, address dvnLow, address dvnHigh)
        internal
        pure
        returns (SetConfigParam memory)
    {
        require(uint160(dvnLow) < uint160(dvnHigh), "DVNs must be sorted ascending");
        address[] memory dvns = new address[](2);
        dvns[0] = dvnLow;
        dvns[1] = dvnHigh;
        return SetConfigParam(
            eid, ULN_CONFIG_TYPE, abi.encode(UlnConfig(confirmations, 2, 0, 0, dvns, new address[](0)))
        );
    }

    function _executor(uint32 eid, address executor) internal pure returns (SetConfigParam memory) {
        return SetConfigParam(eid, EXECUTOR_CONFIG_TYPE, abi.encode(ExecutorConfig(MAX_MESSAGE_SIZE, executor)));
    }
}

interface ILayerZeroEndpointSoBtc {
    function setConfig(address oapp, address lib, SoBtcConfig.SetConfigParam[] calldata params) external;
    function getConfig(address oapp, address lib, uint32 eid, uint32 configType)
        external
        view
        returns (bytes memory);
    function delegates(address oapp) external view returns (address);
    function getSendLibrary(address sender, uint32 eid) external view returns (address);
    function getReceiveLibrary(address receiver, uint32 eid) external view returns (address, bool);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}
