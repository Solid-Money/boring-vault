// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {VmSafe} from "@forge-std/Vm.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IOFT, SendParam} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/**
 * @notice Shared config and plumbing for the BridgePaymasters that send INTO Fuse: one each on
 *         Ethereum, Base and BNB Chain, running the same contract as the Fuse one. Each fronts
 *         Stargate's fee in its chain's native coin and takes it back in the bridged USDC or USDT,
 *         so a user can move stablecoins to Fuse without holding ETH or BNB.
 * @dev The chain is picked from the RPC. Ethereum gets a fresh paymaster beside the existing one at
 *      0xcE0c…a507, which keeps sponsoring the soUSD/soETH teller bridging it already does.
 *
 *      Lifecycle, one script per step:
 *        1. DeployBridgePaymasterToFuse  - deployer key deploys, configures and (optionally) funds it
 *        2. test it with real sends while the deployer still owns it
 *        3. TransferBridgePaymasterToFuseOwnership - hands it to the chain's Safe
 *      ConfigureBridgePaymasterToFuse and PauseBridgePaymasterToFuse work at any point: while the
 *      deployer owns the proxy they send the calls directly; once a Safe owns it they simulate the
 *      calls as the Safe and write a Safe Transaction Builder batch instead.
 */
abstract contract BridgePaymasterToFuseBase is Script {
    uint32 internal constant FUSE = 30138;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    string internal constant BATCH_DIR = "deployments/safe-batches/";

    struct Pool {
        string name;
        address pool;
    }

    struct Network {
        string name;
        /// @dev The folder under deployments/addresses/ that holds this chain's address file.
        string dir;
        Pool[] pools;
        /// @dev One whole token in the pools' local decimals.
        uint256 unit;
    }

    struct OwnerCall {
        string label;
        bytes data;
    }

    /**
     * @dev The Stargate v2 pools that bridge to Fuse on each chain, read from Stargate's v2 metadata
     *      and checked on-chain (`token()`, `quoteSend` to eid 30138). Base has no USDT pool. BNB
     *      Chain's pools hold 18-decimal tokens, so the backend rounds its amounts to whole
     *      6-decimal units there.
     *
     *      Per-send limits match Fuse's product spec: a floor that keeps the network fee a small
     *      share of the send, and a v1 cap.
     */
    function _network() internal view returns (Network memory c) {
        if (block.chainid == 1) {
            c.name = "Ethereum";
            c.dir = "Mainnet";
            c.unit = 1e6;
            c.pools = new Pool[](2);
            c.pools[0] = Pool("Stargate USDC pool", 0xc026395860Db2d07ee33e05fE50ed7bD583189C7);
            c.pools[1] = Pool("Stargate USDT pool", 0x933597a323Eb81cAe705C5bC29985172fd5A3973);
        } else if (block.chainid == 8453) {
            c.name = "Base";
            c.dir = "Base";
            c.unit = 1e6;
            c.pools = new Pool[](1);
            c.pools[0] = Pool("Stargate USDC pool", 0x27a16dc786820B16E5c9028b75B99F6f604b5d26);
        } else if (block.chainid == 56) {
            c.name = "BNB Chain";
            c.dir = "BNB";
            c.unit = 1e18;
            c.pools = new Pool[](2);
            c.pools[0] = Pool("Stargate USDC pool", 0x962Bd449E630b0d928f308Ce63f1A21F02576057);
            c.pools[1] = Pool("Stargate USDT pool", 0x138EB30f73BC423c6455C53df6D89CB01d9eBc63);
        } else {
            revert("run against Ethereum (1), Base (8453) or BNB Chain (56)");
        }
    }

    function _minSend(Network memory c) internal pure returns (uint256) {
        return 5 * c.unit;
    }

    function _maxSend(Network memory c) internal pure returns (uint256) {
        return 10_000 * c.unit;
    }

    /**
     * @dev deployments/addresses/<dir>/BridgePaymaster.json, or BridgePaymaster-<PAYMASTER_LABEL>.json
     *      for a second set beside the production one, such as QA's.
     */
    function _addressFile(Network memory c) internal view returns (string memory) {
        string memory label = vm.envOr("PAYMASTER_LABEL", string(""));
        string memory suffix = bytes(label).length == 0 ? "" : string.concat("-", label);
        return string.concat("deployments/addresses/", c.dir, "/BridgePaymaster", suffix, ".json");
    }

    /// @dev BRIDGE_PAYMASTER if set, else the address DeployBridgePaymasterToFuse recorded for this chain.
    function _paymaster(Network memory c) internal view returns (BridgePaymaster pm) {
        address a = vm.envOr("BRIDGE_PAYMASTER", address(0));
        if (a == address(0)) {
            a = vm.parseJsonAddress(vm.readFile(_addressFile(c)), ".contractAddresses.BridgePaymaster");
        }
        require(a.code.length != 0, "no BridgePaymaster at that address on this chain");
        pm = BridgePaymaster(payable(a));
    }

    /// @dev The owner calls that take `pm` from its current state to the config above.
    function _configCalls(BridgePaymaster pm, Network memory c) internal view returns (OwnerCall[] memory calls) {
        calls = new OwnerCall[](3 * c.pools.length);
        uint256 n;
        for (uint256 i; i < c.pools.length; i++) {
            Pool memory p = c.pools[i];
            if (
                pm.targetKind(p.pool) != BridgePaymaster.TargetKind.STARGATE_OFT
                    || pm.minSponsoredAmount(p.pool) != _minSend(c)
            ) {
                calls[n++] = OwnerCall(
                    string.concat("setTarget(", p.name, ")"),
                    abi.encodeCall(BridgePaymaster.setTarget, (p.pool, BridgePaymaster.TargetKind.STARGATE_OFT, _minSend(c)))
                );
            }
            if (pm.maxSponsoredAmount(p.pool) != _maxSend(c)) {
                calls[n++] = OwnerCall(
                    string.concat("setMaxSponsoredAmount(", p.name, ")"),
                    abi.encodeCall(BridgePaymaster.setMaxSponsoredAmount, (p.pool, _maxSend(c)))
                );
            }
            if (!pm.allowedDstEid(p.pool, FUSE)) {
                calls[n++] = OwnerCall(
                    string.concat("setRoute(", p.name, ", Fuse)"),
                    abi.encodeCall(BridgePaymaster.setRoute, (p.pool, FUSE, true))
                );
            }
        }
        assembly {
            mstore(calls, n)
        }
    }

    /**
     * @dev Applies owner calls to `pm`. An EOA owner must be the broadcasting key, and the calls are
     *      sent. A contract owner (the Safe) cannot be broadcast as, so the calls are simulated as it
     *      and written to `batchFile` for signing.
     */
    function _apply(BridgePaymaster pm, OwnerCall[] memory calls, string memory batchFile, string memory name)
        internal
    {
        if (calls.length == 0) return;
        address owner = pm.owner();
        if (owner.code.length != 0) {
            for (uint256 i; i < calls.length; i++) {
                vm.prank(owner);
                _call(address(pm), calls[i]);
            }
            _writeSafeBatch(address(pm), batchFile, name, calls);
            return;
        }

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(sender == owner, "the broadcasting key is not the paymaster's owner");
        for (uint256 i; i < calls.length; i++) {
            _call(address(pm), calls[i]);
            console2.log("  sent:", calls[i].label);
        }
        vm.stopBroadcast();
    }

    function _call(address to, OwnerCall memory c) internal {
        (bool ok, bytes memory ret) = to.call(c.data);
        if (!ok) {
            console2.log("reverted:", c.label);
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /**
     * @dev Fails unless bridgeSend is set up, every pool, cap and route matches, the EIP-712 domain
     *      is this chain's, and Stargate quotes a send to Fuse through every pool.
     */
    function _assertConfigured(BridgePaymaster pm, Network memory c) internal view {
        require(pm.voucherSigner() != address(0), "voucher signer not set");
        require(pm.feeRecipient() != address(0), "fee recipient not set");
        require(pm.dailyFeeBudget() != 0, "daily fee budget is 0 - every bridgeSend would revert");
        require(_configCalls(pm, c).length == 0, "pools, caps or routes do not match the config");

        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) = pm.eip712Domain();
        require(keccak256(bytes(name)) == keccak256("BridgePaymaster"), "EIP-712 name");
        require(keccak256(bytes(version)) == keccak256("1"), "EIP-712 version");
        require(chainId == block.chainid && verifyingContract == address(pm), "EIP-712 domain");

        for (uint256 i; i < c.pools.length; i++) {
            SendParam memory p = SendParam(FUSE, bytes32(uint256(uint160(address(pm)))), 100 * c.unit, 0, "", "", "");
            require(IOFT(c.pools[i].pool).quoteSend(p, false).nativeFee != 0, "Stargate quotes no send to Fuse");
        }
    }

    function _logState(BridgePaymaster pm, Network memory c) internal view {
        console2.log(string.concat("chain:            ", c.name));
        console2.log("paymaster:        ", address(pm));
        console2.log("implementation:   ", address(uint160(uint256(vm.load(address(pm), IMPLEMENTATION_SLOT)))));
        console2.log("owner:            ", pm.owner());
        console2.log("voucher signer:   ", pm.voucherSigner());
        console2.log("fee recipient:    ", pm.feeRecipient());
        console2.log("daily budget wei: ", pm.dailyFeeBudget());
        console2.log("spent today wei:  ", pm.feeSpentToday());
        console2.log("native balance:   ", address(pm).balance);
        for (uint256 i; i < c.pools.length; i++) {
            Pool memory p = c.pools[i];
            bool ok = pm.targetKind(p.pool) == BridgePaymaster.TargetKind.STARGATE_OFT
                && pm.minSponsoredAmount(p.pool) == _minSend(c) && pm.maxSponsoredAmount(p.pool) == _maxSend(c)
                && pm.allowedDstEid(p.pool, FUSE);
            console2.log(string.concat("  ", ok ? "[ok]     " : "[CHANGE] ", p.name, " -> Fuse"));
        }
    }

    function _writeSafeBatch(address to, string memory file, string memory name, OwnerCall[] memory calls) internal {
        string memory txs;
        for (uint256 i; i < calls.length; i++) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(vm.unixTime()),
            ',"meta":{"name":"',
            name,
            '","description":"',
            vm.toString(calls.length),
            " owner call(s) on ",
            vm.toString(to),
            '","txBuilderVersion":"1.16.5"},"transactions":[',
            txs,
            "]}"
        );
        string memory path = string.concat(BATCH_DIR, file);
        vm.writeFile(path, json);

        console2.log("");
        console2.log("Safe batch written:", path);
        for (uint256 i; i < calls.length; i++) {
            console2.log(string.concat("  ", vm.toString(i + 1), ". ", calls[i].label));
        }
        console2.log("Import it in the Safe Transaction Builder on this chain, sign to threshold, execute.");
    }

    function _batchFile(Network memory c, string memory what) internal pure returns (string memory) {
        return string.concat(c.dir, "-paymaster-to-fuse-", what, ".json");
    }
}

/**
 * @notice Step 1. Deploys a BridgePaymaster (implementation + ERC1967 proxy) owned by the
 *         broadcasting key, sets up bridgeSend, registers this chain's Stargate pools with the route
 *         to Fuse, and optionally funds it. Then checks the result and records the addresses.
 * @dev Env:
 *        VOUCHER_SIGNER        the backend key that signs vouchers (the Fuse paymaster's signer)
 *        FEE_RECIPIENT         where the fee taken in USDC / USDT goes
 *        DAILY_FEE_BUDGET_WEI  native fee bridgeSend may front per UTC day, in wei
 *        FUNDING_WEI           optional: native to send from the deployer (default 0)
 *        IMPLEMENTATION        optional: an implementation already deployed on this chain to put behind
 *                              the proxy, instead of deploying a new one
 *        PAYMASTER_LABEL       optional: records a second set, such as QA's, in its own address file
 *
 *      Dry run (deploys nothing):
 *        forge script script/fuse/BridgePaymasterToFuse.s.sol:DeployBridgePaymasterToFuse \
 *          --rpc-url <ethereum|base|bnb rpc> --skip test --skip script/POC --account <deployer>
 *      Deploy, and verify both contracts:
 *        ... --broadcast --verify --etherscan-api-key <key>
 */
contract DeployBridgePaymasterToFuse is BridgePaymasterToFuseBase {
    function run() external {
        Network memory c = _network();

        address voucherSigner = vm.envAddress("VOUCHER_SIGNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 dailyFeeBudget = vm.envUint("DAILY_FEE_BUDGET_WEI");
        uint256 funding = vm.envOr("FUNDING_WEI", uint256(0));

        address implementation = vm.envOr("IMPLEMENTATION", address(0));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        if (implementation == address(0)) implementation = address(new BridgePaymaster());
        require(implementation.code.length != 0, "IMPLEMENTATION has no code on this chain");
        BridgePaymaster pm = BridgePaymaster(
            payable(address(new ERC1967Proxy(implementation, abi.encodeCall(BridgePaymaster.initialize, (deployer)))))
        );
        pm.initializeV2(voucherSigner, feeRecipient, dailyFeeBudget);

        OwnerCall[] memory calls = _configCalls(pm, c);
        for (uint256 i; i < calls.length; i++) {
            _call(address(pm), calls[i]);
        }

        if (funding != 0) {
            (bool funded,) = address(pm).call{value: funding}("");
            require(funded, "funding transfer failed");
        }
        vm.stopBroadcast();

        require(pm.owner() == deployer, "owner is not the deployer");
        require(
            address(uint160(uint256(vm.load(address(pm), IMPLEMENTATION_SLOT)))) == implementation,
            "proxy does not point at the implementation"
        );
        require(pm.voucherSigner() == voucherSigner, "voucher signer");
        require(pm.feeRecipient() == feeRecipient, "fee recipient");
        require(pm.dailyFeeBudget() == dailyFeeBudget, "daily fee budget");
        _assertConfigured(pm, c);

        console2.log("deployer:         ", deployer);
        _logState(pm, c);
        console2.log(string.concat("configured with ", vm.toString(calls.length), " owner call(s); checks passed."));

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory file = _addressFile(c);
            vm.writeFile(
                file,
                string.concat(
                    '{\n  "network": "',
                    c.name,
                    '",\n  "chainId": ',
                    vm.toString(block.chainid),
                    ',\n  "contractAddresses": {"BridgePaymaster":"',
                    vm.toString(address(pm)),
                    '","BridgePaymasterImplementation":"',
                    vm.toString(implementation),
                    '"}\n}\n'
                )
            );
            console2.log("addresses written:", file);
        } else {
            console2.log("DRY RUN - nothing deployed, no addresses written. Add --broadcast to deploy.");
        }
        console2.log("Next: test with real sends, then TransferBridgePaymasterToFuseOwnership.");
    }
}

/**
 * @notice Step 3. Hands the paymaster to the chain's Safe once it has been tested. `transferOwnership`
 *         is single-step, so the new owner is checked to be a Safe with a threshold of at least 2
 *         before anything is sent.
 * @dev Env: NEW_OWNER (the Safe on this chain), BRIDGE_PAYMASTER (optional, defaults to the recorded
 *      address).
 *
 *        forge script script/fuse/BridgePaymasterToFuse.s.sol:TransferBridgePaymasterToFuseOwnership \
 *          --rpc-url <rpc> --skip test --skip script/POC --account <deployer> --broadcast
 */
contract TransferBridgePaymasterToFuseOwnership is BridgePaymasterToFuseBase {
    function run() external {
        Network memory c = _network();
        BridgePaymaster pm = _paymaster(c);
        address newOwner = vm.envAddress("NEW_OWNER");

        require(newOwner.code.length != 0, "NEW_OWNER has no code - refusing to hand the paymaster to an EOA");
        uint256 threshold = ISafe(newOwner).getThreshold();
        address[] memory signers = ISafe(newOwner).getOwners();
        require(threshold >= 2, "NEW_OWNER's threshold is below 2");
        console2.log("new owner (Safe):", newOwner);
        console2.log(string.concat("  threshold ", vm.toString(threshold), " of ", vm.toString(signers.length)));

        _assertConfigured(pm, c);
        _logState(pm, c);

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(sender == pm.owner(), "the broadcasting key is not the paymaster's owner");
        pm.transferOwnership(newOwner);
        vm.stopBroadcast();

        require(pm.owner() == newOwner, "ownership did not move");
        console2.log("Ownership moved. From here every owner call goes through the Safe.");
    }
}

/**
 * @notice Reports the paymaster's state and applies any difference from the config: sent directly
 *         while the deployer owns it, written as a Safe batch once the Safe does.
 *
 *        forge script script/fuse/BridgePaymasterToFuse.s.sol:ConfigureBridgePaymasterToFuse \
 *          --rpc-url <rpc> --skip test --skip script/POC [--account <deployer> --broadcast]
 */
contract ConfigureBridgePaymasterToFuse is BridgePaymasterToFuseBase {
    function run() external {
        Network memory c = _network();
        BridgePaymaster pm = _paymaster(c);
        _logState(pm, c);

        OwnerCall[] memory calls = _configCalls(pm, c);
        if (calls.length == 0) {
            console2.log("Everything matches - nothing to do.");
            return;
        }
        _apply(pm, calls, _batchFile(c, "config"), string.concat("BridgePaymaster to Fuse config (", c.name, ")"));
        _assertConfigured(pm, c);
    }
}

/**
 * @notice Kill switch: deregisters this chain's pools, so every `bridgeSend` reverts with
 *         UnsupportedTarget. Re-running ConfigureBridgePaymasterToFuse turns it back on.
 *
 *        forge script script/fuse/BridgePaymasterToFuse.s.sol:PauseBridgePaymasterToFuse \
 *          --rpc-url <rpc> --skip test --skip script/POC [--account <deployer> --broadcast]
 */
contract PauseBridgePaymasterToFuse is BridgePaymasterToFuseBase {
    function run() external {
        Network memory c = _network();
        BridgePaymaster pm = _paymaster(c);
        OwnerCall[] memory calls = new OwnerCall[](c.pools.length);
        for (uint256 i; i < c.pools.length; i++) {
            calls[i] = OwnerCall(
                string.concat("setTarget(", c.pools[i].name, ", NONE)"),
                abi.encodeCall(BridgePaymaster.setTarget, (c.pools[i].pool, BridgePaymaster.TargetKind.NONE, 0))
            );
        }
        _apply(pm, calls, _batchFile(c, "pause"), string.concat("Pause bridgeSend to Fuse (", c.name, ")"));
        for (uint256 i; i < c.pools.length; i++) {
            require(pm.targetKind(c.pools[i].pool) == BridgePaymaster.TargetKind.NONE, "pool still registered");
        }
    }
}
