// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {VmSafe} from "@forge-std/Vm.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SendParam} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/**
 * @notice Shared config and plumbing for the fresh Fuse BridgePaymaster that replaces 0xE046…Dac10.
 * @dev Lifecycle, one script per step:
 *        1. DeployBridgePaymaster        - deployer key deploys, configures and (optionally) funds it
 *        2. test it with real sends while the deployer still owns it
 *        3. TransferBridgePaymasterOwnership - hands it to the Safe
 *        4. DrainOldPaymaster            - Safe batch: retire the old paymaster, move its FUSE here
 *      ConfigureBridgePaymaster and PauseBridgeSend work at any point: while the deployer owns the
 *      proxy they send the calls directly; once the Safe owns it they simulate the calls as the Safe
 *      and write a Safe Transaction Builder batch instead.
 */
abstract contract BridgePaymasterFuseBase is Script {
    /// @dev The paymaster being replaced. Its FUSE moves to the new one in step 4.
    BridgePaymaster internal constant OLD_PAYMASTER = BridgePaymaster(payable(0xE046FC894Ec020501BA32fcA814a69B49c9Dac10));

    /// @dev Owner of the old paymaster and of the tellers' authorities; the new paymaster's final owner.
    address internal constant OWNER_SAFE = 0xBA308f2919aa20fbD58fc7406451077fe32F1F29;

    /// @dev Stargate v2 Hydra OFTs on Fuse (Stargate USDC.e and USDT, 6 decimals).
    address internal constant USDC_OFT = 0xAF54BE5B6eEc24d6BFACf1cce4eaF680A8239398;
    address internal constant USDT_OFT = 0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6;

    address internal constant CARD_DEPOSIT_MANAGER = 0x22BBc13D022735f2586d4eb04a93f0F4E0173E50;

    uint32 internal constant ETHEREUM = 30101;
    uint32 internal constant BNB = 30102;
    uint32 internal constant ARBITRUM = 30110;
    uint32 internal constant BASE = 30184;

    /// @dev The product spec's limits: a floor that keeps the network fee a small share of the send,
    ///      and a v1 cap per send.
    uint256 internal constant MIN_SEND = 5e6;
    uint256 internal constant MAX_SEND = 10_000e6;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    string internal constant ADDRESS_FILE = "deployments/addresses/Fuse/BridgePaymaster.json";
    string internal constant BATCH_DIR = "deployments/safe-batches/";

    struct Target {
        string name;
        address target;
        BridgePaymaster.TargetKind kind;
        uint256 minAmount;
    }

    struct OwnerCall {
        string label;
        bytes data;
    }

    /**
     * @dev Every target the new paymaster sponsors. The first three are the ones registered on the old
     *      paymaster today, so the new one can take over every live flow. Their floors are still 0, as
     *      on the old one - a product call, see the product spec's limits; changing one here and
     *      re-running ConfigureBridgePaymaster applies it.
     *
     *      Not carried over, because they were never registered on the old proxy either: the staging
     *      tellers (0xcBA3…963d, 0x39D0…74B6) and the fastWithdrawManager (0x0bA1…Ea1b), so
     *      `sponsorFastWithdraw` reverts with UnsupportedTarget today. Registering them is its own
     *      decision.
     *
     *      The tellers' `bridge` is a public capability and CardDepositManager has no caller check, so
     *      no role has to be granted to the new address for these to work.
     */
    function _targets() internal pure returns (Target[] memory t) {
        t = new Target[](5);
        t[0] = Target("teller (soUSD, prod)", 0x220d4667AA06E0Aa39f62c601690848f2e48BC15, BridgePaymaster.TargetKind.TELLER, 0);
        t[1] = Target("soEthTeller (prod)", 0xEaacf4534cCC05CAd929830fAF611d872b291d41, BridgePaymaster.TargetKind.TELLER, 0);
        t[2] = Target("cardDepositManager", CARD_DEPOSIT_MANAGER, BridgePaymaster.TargetKind.CARD_DEPOSIT_MANAGER, 0);
        t[3] = Target("Stargate USDC.e OFT", USDC_OFT, BridgePaymaster.TargetKind.STARGATE_OFT, MIN_SEND);
        t[4] = Target("Stargate USDT OFT", USDT_OFT, BridgePaymaster.TargetKind.STARGATE_OFT, MIN_SEND);
    }

    /// @dev Destinations per OFT. Base has no standard USDT, so USDT never goes there.
    function _routes(address oft) internal pure returns (uint32[] memory eids) {
        if (oft == USDC_OFT) {
            eids = new uint32[](4);
            (eids[0], eids[1], eids[2], eids[3]) = (ARBITRUM, BASE, BNB, ETHEREUM);
        } else if (oft == USDT_OFT) {
            eids = new uint32[](3);
            (eids[0], eids[1], eids[2]) = (ARBITRUM, BNB, ETHEREUM);
        }
    }

    /// @dev The new paymaster: BRIDGE_PAYMASTER if set, else the address DeployBridgePaymaster recorded.
    function _paymaster() internal view returns (BridgePaymaster pm) {
        address a = vm.envOr("BRIDGE_PAYMASTER", address(0));
        if (a == address(0)) {
            a = vm.parseJsonAddress(vm.readFile(ADDRESS_FILE), ".contractAddresses.BridgePaymaster");
        }
        require(a.code.length != 0, "no BridgePaymaster at that address on this chain");
        require(a != address(OLD_PAYMASTER), "that is the old paymaster");
        pm = BridgePaymaster(payable(a));
    }

    /// @dev The owner calls that take `pm` from its current state to the config above.
    function _configCalls(BridgePaymaster pm) internal view returns (OwnerCall[] memory calls) {
        Target[] memory targets = _targets();
        calls = new OwnerCall[](64);
        uint256 n;

        for (uint256 i; i < targets.length; i++) {
            Target memory t = targets[i];
            if (pm.targetKind(t.target) != t.kind || pm.minSponsoredAmount(t.target) != t.minAmount) {
                calls[n++] = OwnerCall(
                    string.concat("setTarget(", t.name, ")"),
                    abi.encodeCall(BridgePaymaster.setTarget, (t.target, t.kind, t.minAmount))
                );
            }
            if (t.kind != BridgePaymaster.TargetKind.STARGATE_OFT) continue;

            if (pm.maxSponsoredAmount(t.target) != MAX_SEND) {
                calls[n++] = OwnerCall(
                    string.concat("setMaxSponsoredAmount(", t.name, ")"),
                    abi.encodeCall(BridgePaymaster.setMaxSponsoredAmount, (t.target, MAX_SEND))
                );
            }
            uint32[] memory eids = _routes(t.target);
            for (uint256 j; j < eids.length; j++) {
                if (pm.allowedDstEid(t.target, eids[j])) continue;
                calls[n++] = OwnerCall(
                    string.concat("setRoute(", t.name, ", ", vm.toString(eids[j]), ")"),
                    abi.encodeCall(BridgePaymaster.setRoute, (t.target, eids[j], true))
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
            _simulateAs(owner, address(pm), calls);
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

    /// @dev Runs `calls` on `to` as `caller` on the fork; any revert aborts the script.
    function _simulateAs(address caller, address to, OwnerCall[] memory calls) internal {
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            _call(to, calls[i]);
        }
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

    /// @dev Fails unless the bridgeSend settings are set and every target, cap and route matches.
    function _assertConfigured(BridgePaymaster pm) internal view {
        require(pm.voucherSigner() != address(0), "voucher signer not set");
        require(pm.feeRecipient() != address(0), "fee recipient not set");
        require(pm.dailyFeeBudget() != 0, "daily fee budget is 0 - every bridgeSend would revert");
        require(_configCalls(pm).length == 0, "targets, caps or routes do not match the config");

        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) = pm.eip712Domain();
        require(keccak256(bytes(name)) == keccak256("BridgePaymaster"), "EIP-712 name");
        require(keccak256(bytes(version)) == keccak256("1"), "EIP-712 version");
        require(chainId == 122 && verifyingContract == address(pm), "EIP-712 domain");
    }

    /// @dev Stand-in recipient for the probe below; it is never sent anything.
    address internal constant DROP_RECEIVER = 0x000000000000000000000000000000000000dEaD;

    /// @dev The fix for the old paymaster's drain: a native gas drop in the options must be refused.
    function _assertRejectsOptions(BridgePaymaster pm) internal {
        SendParam memory sendParam = SendParam({
            dstEid: ARBITRUM,
            to: bytes32(uint256(uint160(DROP_RECEIVER))),
            amountLD: 1e6,
            minAmountLD: 0,
            extraOptions: abi.encodePacked(
                uint16(3), uint8(1), uint16(49), uint8(2), uint128(0.01 ether), bytes32(uint256(uint160(DROP_RECEIVER)))
            ),
            composeMsg: "",
            oftCmd: ""
        });
        try pm.sponsorCardDeposit(CARD_DEPOSIT_MANAGER, USDC_OFT, sendParam) {
            revert("sponsorCardDeposit accepted a native gas drop");
        } catch (bytes memory err) {
            require(bytes4(err) == BridgePaymaster.OptionsNotAllowed.selector, "expected OptionsNotAllowed");
        }
    }

    function _logState(BridgePaymaster pm) internal view {
        console2.log("paymaster:       ", address(pm));
        console2.log("implementation:  ", address(uint160(uint256(vm.load(address(pm), IMPLEMENTATION_SLOT)))));
        console2.log("owner:           ", pm.owner());
        console2.log("voucher signer:  ", pm.voucherSigner());
        console2.log("fee recipient:   ", pm.feeRecipient());
        console2.log("daily budget wei:", pm.dailyFeeBudget());
        console2.log("spent today wei: ", pm.feeSpentToday());
        console2.log("native balance:  ", address(pm).balance);
        Target[] memory targets = _targets();
        for (uint256 i; i < targets.length; i++) {
            Target memory t = targets[i];
            bool ok = pm.targetKind(t.target) == t.kind && pm.minSponsoredAmount(t.target) == t.minAmount;
            console2.log(string.concat("  ", ok ? "[ok]     " : "[CHANGE] ", t.name, " min ", vm.toString(t.minAmount)));
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
            '{"version":"1.0","chainId":"122","createdAt":',
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
        console2.log("Import it in the Safe Transaction Builder (Fuse), sign to threshold, execute.");
    }

    function _requireFuse() internal view {
        require(block.chainid == 122, "run against Fuse: --rpc-url https://rpc.fuse.io");
    }
}

/**
 * @notice Step 1. Deploys a fresh BridgePaymaster (implementation + ERC1967 proxy) owned by the
 *         broadcasting key, sets up bridgeSend, registers every target, cap and route, and optionally
 *         funds it for testing. Then checks the result and records the addresses.
 * @dev Env:
 *        VOUCHER_SIGNER     the backend key that signs vouchers
 *        FEE_RECIPIENT      where the fee taken in USDC.e / USDT goes
 *        DAILY_FEE_BUDGET   whole FUSE bridgeSend may front per UTC day, e.g. 20000
 *        TEST_FUNDING       optional: whole FUSE to send from the deployer for testing (default 0)
 *
 *      Dry run (deploys nothing):
 *        forge script script/fuse/BridgePaymasterBridgeSend.s.sol:DeployBridgePaymaster \
 *          --rpc-url https://rpc.fuse.io --skip test --skip script/POC --account <deployer>
 *      Deploy, and verify both contracts on the Fuse explorer:
 *        ... --broadcast --verify --verifier blockscout --verifier-url https://explorer.fuse.io/api/
 */
contract DeployBridgePaymaster is BridgePaymasterFuseBase {
    function run() external {
        _requireFuse();

        address voucherSigner = vm.envAddress("VOUCHER_SIGNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 dailyFeeBudget = vm.envUint("DAILY_FEE_BUDGET") * 1 ether;
        uint256 testFunding = vm.envOr("TEST_FUNDING", uint256(0)) * 1 ether;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        BridgePaymaster implementation = new BridgePaymaster();
        BridgePaymaster pm = BridgePaymaster(
            payable(
                address(
                    new ERC1967Proxy(address(implementation), abi.encodeCall(BridgePaymaster.initialize, (deployer)))
                )
            )
        );
        pm.initializeV2(voucherSigner, feeRecipient, dailyFeeBudget);

        OwnerCall[] memory calls = _configCalls(pm);
        for (uint256 i; i < calls.length; i++) {
            _call(address(pm), calls[i]);
        }

        if (testFunding != 0) {
            (bool funded,) = address(pm).call{value: testFunding}("");
            require(funded, "funding transfer failed");
        }
        vm.stopBroadcast();

        require(pm.owner() == deployer, "owner is not the deployer");
        require(
            address(uint160(uint256(vm.load(address(pm), IMPLEMENTATION_SLOT)))) == address(implementation),
            "proxy does not point at the implementation"
        );
        require(pm.voucherSigner() == voucherSigner, "voucher signer");
        require(pm.feeRecipient() == feeRecipient, "fee recipient");
        require(pm.dailyFeeBudget() == dailyFeeBudget, "daily fee budget");
        _assertConfigured(pm);
        _assertRejectsOptions(pm);

        console2.log("deployer:        ", deployer);
        console2.log("implementation:  ", address(implementation));
        _logState(pm);
        console2.log(string.concat("configured with ", vm.toString(calls.length), " owner call(s); checks passed."));

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.writeFile(
                ADDRESS_FILE,
                string.concat(
                    '{\n  "network": "Fuse",\n  "chainId": 122,\n  "contractAddresses": {"BridgePaymaster":"',
                    vm.toString(address(pm)),
                    '","BridgePaymasterImplementation":"',
                    vm.toString(address(implementation)),
                    '"}\n}\n'
                )
            );
            console2.log("addresses written:", ADDRESS_FILE);
        } else {
            console2.log("DRY RUN - nothing deployed, no addresses written. Add --broadcast to deploy.");
        }
        console2.log("Next: test with real sends, then TransferBridgePaymasterOwnership.");
    }
}

/**
 * @notice Step 3. Hands the new paymaster to the Safe once it has been tested. `transferOwnership`
 *         is single-step, so the new owner is checked to be a Safe with a threshold of at least 2
 *         before anything is sent.
 * @dev Env: NEW_OWNER (optional, defaults to the Safe that owns the old paymaster), BRIDGE_PAYMASTER
 *      (optional, defaults to the recorded address).
 *
 *        forge script script/fuse/BridgePaymasterBridgeSend.s.sol:TransferBridgePaymasterOwnership \
 *          --rpc-url https://rpc.fuse.io --skip test --skip script/POC --account <deployer> --broadcast
 */
contract TransferBridgePaymasterOwnership is BridgePaymasterFuseBase {
    function run() external {
        _requireFuse();
        BridgePaymaster pm = _paymaster();
        address newOwner = vm.envOr("NEW_OWNER", OWNER_SAFE);

        require(newOwner.code.length != 0, "NEW_OWNER has no code - refusing to hand the paymaster to an EOA");
        uint256 threshold = ISafe(newOwner).getThreshold();
        address[] memory signers = ISafe(newOwner).getOwners();
        require(threshold >= 2, "NEW_OWNER's threshold is below 2");
        console2.log("new owner (Safe):", newOwner);
        console2.log(string.concat("  threshold ", vm.toString(threshold), " of ", vm.toString(signers.length)));

        _assertConfigured(pm);
        _logState(pm);

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
 * @notice Step 4. Writes the Safe batch that retires the OLD paymaster: deregisters its three targets
 *         (closing its gas-drop hole for good) and moves its whole FUSE balance to the new paymaster.
 * @dev Run it only after the app and backend point at the new paymaster - the old flows stop working
 *      the moment this executes. Refuses unless the new paymaster is already owned by the Safe and
 *      fully configured, so the FUSE never lands in a contract an EOA controls.
 *
 *        forge script script/fuse/BridgePaymasterBridgeSend.s.sol:DrainOldPaymaster \
 *          --rpc-url https://rpc.fuse.io --skip test --skip script/POC
 */
contract DrainOldPaymaster is BridgePaymasterFuseBase {
    function run() external {
        _requireFuse();
        BridgePaymaster pm = _paymaster();
        require(pm.owner() == OWNER_SAFE, "move the new paymaster to the Safe first");
        _assertConfigured(pm);

        address oldOwner = OLD_PAYMASTER.owner();
        uint256 oldBalance = address(OLD_PAYMASTER).balance;
        uint256 newBalance = address(pm).balance;
        console2.log("old paymaster balance wei:", oldBalance);
        console2.log("new paymaster balance wei:", newBalance);

        Target[] memory targets = _targets();
        OwnerCall[] memory calls = new OwnerCall[](4);
        uint256 n;
        for (uint256 i; i < targets.length; i++) {
            if (targets[i].kind == BridgePaymaster.TargetKind.STARGATE_OFT) continue;
            calls[n++] = OwnerCall(
                string.concat("old: setTarget(", targets[i].name, ", NONE)"),
                abi.encodeCall(BridgePaymaster.setTarget, (targets[i].target, BridgePaymaster.TargetKind.NONE, 0))
            );
        }
        calls[n++] = OwnerCall("old: rescueNative(new paymaster)", abi.encodeCall(BridgePaymaster.rescueNative, (address(pm))));
        assembly {
            mstore(calls, n)
        }

        _simulateAs(oldOwner, address(OLD_PAYMASTER), calls);
        for (uint256 i; i < targets.length; i++) {
            if (targets[i].kind == BridgePaymaster.TargetKind.STARGATE_OFT) continue;
            require(OLD_PAYMASTER.targetKind(targets[i].target) == BridgePaymaster.TargetKind.NONE, "old target still set");
        }
        require(address(OLD_PAYMASTER).balance == 0, "old paymaster not emptied");
        require(address(pm).balance == newBalance + oldBalance, "FUSE did not arrive at the new paymaster");

        console2.log("Simulated as the Safe: old targets deregistered, all FUSE moved to the new paymaster.");
        console2.log("Execute only after the app and backend use the new paymaster.");
        _writeSafeBatch(address(OLD_PAYMASTER), "fuse-old-paymaster-drain.json", "Retire old BridgePaymaster (fuse)", calls);
    }
}

/**
 * @notice Reports the new paymaster's state and applies any difference from the config: sent directly
 *         while the deployer owns it, written as a Safe batch once the Safe does. After every step
 *         each row should read [ok] and nothing is applied.
 *
 *        forge script script/fuse/BridgePaymasterBridgeSend.s.sol:ConfigureBridgePaymaster \
 *          --rpc-url https://rpc.fuse.io --skip test --skip script/POC [--account <deployer> --broadcast]
 */
contract ConfigureBridgePaymaster is BridgePaymasterFuseBase {
    function run() external {
        _requireFuse();
        BridgePaymaster pm = _paymaster();
        _logState(pm);

        OwnerCall[] memory calls = _configCalls(pm);
        if (calls.length == 0) {
            console2.log("Everything matches - nothing to do.");
            return;
        }
        _apply(pm, calls, "fuse-paymaster-config.json", "BridgePaymaster config (fuse)");
        _assertConfigured(pm);
    }
}

/**
 * @notice Kill switch: deregisters both Stargate OFTs on the new paymaster, so every `bridgeSend`
 *         reverts with UnsupportedTarget. Card deposits and teller bridging carry on. Re-running
 *         ConfigureBridgePaymaster turns it back on.
 *
 *        forge script script/fuse/BridgePaymasterBridgeSend.s.sol:PauseBridgeSend \
 *          --rpc-url https://rpc.fuse.io --skip test --skip script/POC [--account <deployer> --broadcast]
 */
contract PauseBridgeSend is BridgePaymasterFuseBase {
    function run() external {
        _requireFuse();
        BridgePaymaster pm = _paymaster();
        OwnerCall[] memory calls = new OwnerCall[](2);
        calls[0] = OwnerCall(
            "setTarget(Stargate USDC.e OFT, NONE)",
            abi.encodeCall(BridgePaymaster.setTarget, (USDC_OFT, BridgePaymaster.TargetKind.NONE, 0))
        );
        calls[1] = OwnerCall(
            "setTarget(Stargate USDT OFT, NONE)",
            abi.encodeCall(BridgePaymaster.setTarget, (USDT_OFT, BridgePaymaster.TargetKind.NONE, 0))
        );
        _apply(pm, calls, "fuse-paymaster-pause-bridge-send.json", "Pause bridgeSend (fuse)");
        require(pm.targetKind(USDC_OFT) == BridgePaymaster.TargetKind.NONE, "USDC.e OFT still registered");
        require(pm.targetKind(USDT_OFT) == BridgePaymaster.TargetKind.NONE, "USDT OFT still registered");
    }
}
