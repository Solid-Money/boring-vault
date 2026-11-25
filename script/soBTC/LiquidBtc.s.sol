// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SolidLiquidBTCDecoderAndSanitizer} from
    "src/base/DecodersAndSanitizers/Solid/SolidLiquidBTCDecoderAndSanitizer.sol";

/**
 * soBTC (Ethereum) into ether.fi Liquid BTC: WBTC in through the liquidBTC teller, out in two queue hops,
 * liquidBTC -> eBTC on the liquidBTC queue, then eBTC -> WBTC on the eBTC queue.
 *
 *   1. deploy the decoder (deployer 0x3B69):
 *        LIQUIDBTC_STEP=deploy forge script script/soBTC/LiquidBtc.s.sol --rpc-url mainnet \
 *          --private-key $PRIVATE_KEY [--broadcast]
 *   2. the root and proofs, from solid-backend (the decoder's address is in constants/decoderAndSanitizers):
 *        ts-node -r tsconfig-paths/register \
 *          scripts/sobtc-liquidbtc-proofs.ts <boring-vault>/deployments/safe-batches/eth-sobtc-liquidbtc-proofs.json
 *   3. rehearse on a mainnet fork (nothing is sent; a decoder not yet deployed is etched at the proofs' address;
 *      ether.fi's contracts need PUSH0, hence cancun):
 *        LIQUIDBTC_STEP=rehearse LIQUIDBTC_PROOFS=deployments/safe-batches/eth-sobtc-liquidbtc-proofs.json \
 *          forge script script/soBTC/LiquidBtc.s.sol --rpc-url mainnet --evm-version cancun
 *      Nov 25 2026, passed: 0.1 WBTC -> 0.09650934 liquidBTC -> 0.09955384 eBTC -> 0.09998998 WBTC, plus a
 *      replace past the deadline, a cancel, and the manager refusing a WBTC exit, a WBTC approve to the teller
 *      and a cancel of another user's request.
 *   4. the Ethereum Safe batch (simulated as the Safe, written to deployments/safe-batches). No --evm-version here:
 *      it checks the deployed decoder against this build, which must match the deploy's (london, foundry.toml):
 *        LIQUIDBTC_STEP=batch LIQUIDBTC_PROOFS=deployments/safe-batches/eth-sobtc-liquidbtc-proofs.json \
 *          forge script script/soBTC/LiquidBtc.s.sol --rpc-url mainnet
 *
 *   The proofs file must sit inside the repo (fs_permissions). Nov 26 2026: decoder 0xfE96197cB0d6d9f16c2623D67B2E357a43d96aBb
 *   (tx 0xce97aa848b47fb65e88c082fe3536a0124ef9ef9b729d2c9a4218cbe9111c1b7), root 0x53cdbf03…789a; the rehearsal
 *   passed again against the deployed decoder.
 */
contract LiquidBtc is Script, StdCheats {
    // soBTC on Ethereum (deployments/addresses/Mainnet/soBTC.json)
    address internal constant VAULT = 0x4518Af8B68DBabc2Bdf9b6922ACA30ea8939979F;
    address internal constant MANAGER = 0xebEFf15530CDC851A6Ce49F925B609402c4e4554;
    address internal constant SAFE = 0x6B26fAF3AD822695127B29ad242ac4B33D336F42;
    address internal constant STRATEGIST = 0x6f3334EC6355eD6f70100Cd1Cd6736505cd0F9b5;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // ether.fi Liquid BTC
    address internal constant LIQUID = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address internal constant LIQUID_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address internal constant LIQUID_ACCOUNTANT = 0xEa23aC6D7D11f6b181d6B98174D334478ADAe6b0;
    address internal constant LIQUID_QUEUE = 0x77A2fd42F8769d8063F2E75061FC200014E41Edf;
    address internal constant LIQUID_SOLVER = 0xED41172438897BcB22c9dd72B9F9bbF9A8bF8929;
    // ether.fi eBTC
    address internal constant EBTC = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address internal constant EBTC_QUEUE = 0x686696A3e59eE16e8A8533d84B62cfA504827135;
    address internal constant EBTC_SOLVER = 0x7aa7CB90eF6677B4389B0eB707c4c7208897Bee8;

    bytes32 internal constant REQUESTED = keccak256(
        "OnChainWithdrawRequested(bytes32,address,address,uint96,uint128,uint128,uint40,uint24,uint24)"
    );

    string internal proofs;
    address internal decoder;

    function run() external {
        require(block.chainid == 1, "Ethereum only");
        bytes32 step = keccak256(bytes(vm.envString("LIQUIDBTC_STEP")));
        if (step == keccak256("deploy")) return _deploy();
        proofs = vm.readFile(vm.envString("LIQUIDBTC_PROOFS"));
        decoder = vm.parseJsonAddress(proofs, ".decoder");
        require(vm.parseJsonAddress(proofs, ".vault") == VAULT, "proofs are for another vault");
        if (step == keccak256("batch")) return _batch();
        if (step == keccak256("rehearse")) return _rehearse();
        revert("LIQUIDBTC_STEP: deploy | batch | rehearse");
    }

    // ===================================== DEPLOY =====================================

    function _deploy() internal {
        vm.startBroadcast();
        SolidLiquidBTCDecoderAndSanitizer d = new SolidLiquidBTCDecoderAndSanitizer();
        vm.stopBroadcast();
        console.log("SolidLiquidBTCDecoderAndSanitizer", address(d));
        console.log("set LIQUIDBTC_DECODER_ADDRESS_ETHEREUM to it in solid-backend, then build the root (step 2)");
    }

    // ===================================== BATCH =====================================

    function _batch() internal {
        require(
            decoder.codehash == keccak256(type(SolidLiquidBTCDecoderAndSanitizer).runtimeCode),
            "the proofs' decoder is not this build of SolidLiquidBTCDecoderAndSanitizer"
        );
        bytes32 root = vm.parseJsonBytes32(proofs, ".root");
        bytes memory data = abi.encodeCall(IManager.setManageRoot, (STRATEGIST, root));
        vm.prank(SAFE);
        (bool ok,) = MANAGER.call(data);
        require(ok && IManager(MANAGER).manageRoot(STRATEGIST) == root, "setManageRoot");

        string memory path = "deployments/safe-batches/eth-sobtc-liquidbtc-root.json";
        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": "1",\n  "createdAt": ',
            vm.toString(block.timestamp * 1000),
            ',\n  "meta": {\n    "name": "Ethereum soBTC: strategist root with ether.fi Liquid BTC",\n',
            '    "description": "Manager 0xebEF setManageRoot(strategist 0x6f33, ',
            vm.toString(root),
            "): adds WBTC deposits into liquidBTC and its two-hop exit (liquidBTC -> eBTC -> WBTC), decoder ",
            vm.toString(decoder),
            '.",\n    "txBuilderVersion": "1.16.5",\n    "createdFromSafeAddress": "',
            vm.toString(SAFE),
            '"\n  },\n  "transactions": [\n    {"to": "',
            vm.toString(MANAGER),
            '", "value": "0", "data": "',
            vm.toString(data),
            '", "contractMethod": null, "contractInputsValues": null}\n  ]\n}\n'
        );
        vm.writeFile(path, json);
        console.log("wrote %s", path);
    }

    // ===================================== REHEARSE =====================================

    function _rehearse() internal {
        if (decoder.code.length == 0) {
            vm.etch(decoder, type(SolidLiquidBTCDecoderAndSanitizer).runtimeCode);
            console.log("decoder not deployed; etched at %s for the rehearsal", decoder);
        }
        vm.prank(SAFE);
        IManager(MANAGER).setManageRoot(STRATEGIST, vm.parseJsonBytes32(proofs, ".root"));

        uint256 amount = 1e7; // 0.1 WBTC
        _give(WBTC, VAULT, amount);
        uint256 wbtcStart = IERC20(WBTC).balanceOf(VAULT);

        console.log("=== 1. deposit 0.1 WBTC");
        uint256 rate = IAccountant(LIQUID_ACCOUNTANT).getRateInQuoteSafe(WBTC);
        uint256 expected = amount * 1e8 / rate;
        _manage2(
            "approveDepositAsset",
            WBTC,
            abi.encodeCall(IERC20.approve, (LIQUID, amount)),
            "deposit",
            LIQUID_TELLER,
            abi.encodeCall(ITeller.deposit, (WBTC, amount, expected * 9990 / 10000))
        );
        uint256 shares = IERC20(LIQUID).balanceOf(VAULT);
        console.log("liquidBTC shares %s (want %s)", shares, expected);
        require(shares == expected, "shares");

        console.log("=== 2. request eBTC for the shares on the liquidBTC queue");
        vm.recordLogs();
        _manage2(
            "approveHop0",
            LIQUID,
            abi.encodeCall(IERC20.approve, (LIQUID_QUEUE, shares)),
            "requestHop0",
            LIQUID_QUEUE,
            abi.encodeCall(IQueue.requestOnChainWithdraw, (EBTC, uint128(shares), 1, 604800))
        );
        OnChainWithdraw memory first = _requested(LIQUID_QUEUE);
        console.log("request: %s shares -> %s eBTC", first.amountOfShares, first.amountOfAssets);
        require(IERC20(LIQUID).balanceOf(VAULT) == 0, "shares left in the vault");

        console.log("=== 3. ether.fi's solver fills it after maturity");
        vm.warp(block.timestamp + first.secondsToMaturity + 1);
        _solve(LIQUID_QUEUE, LIQUID_SOLVER, EBTC, first);
        uint256 ebtc = IERC20(EBTC).balanceOf(VAULT);
        console.log("vault eBTC %s", ebtc);
        require(ebtc >= first.amountOfAssets, "eBTC not paid");

        console.log("=== 4. request WBTC for the eBTC on the eBTC queue");
        vm.recordLogs();
        _manage2(
            "approveHop1",
            EBTC,
            abi.encodeCall(IERC20.approve, (EBTC_QUEUE, ebtc)),
            "requestHop1",
            EBTC_QUEUE,
            abi.encodeCall(IQueue.requestOnChainWithdraw, (WBTC, uint128(ebtc), 0, 1209600))
        );
        OnChainWithdraw memory second = _requested(EBTC_QUEUE);
        console.log("request: %s eBTC -> %s WBTC", second.amountOfShares, second.amountOfAssets);

        console.log("=== 5. eBTC's solver fills it after maturity");
        vm.warp(block.timestamp + second.secondsToMaturity + 1);
        _solve(EBTC_QUEUE, EBTC_SOLVER, WBTC, second);
        uint256 wbtcEnd = IERC20(WBTC).balanceOf(VAULT);
        console.log("vault WBTC back: %s of %s in", wbtcEnd - (wbtcStart - amount), amount);
        require(wbtcEnd - (wbtcStart - amount) == second.amountOfAssets, "WBTC not paid");

        console.log("=== 6. a request past its deadline is replaced at the current rate");
        _give(WBTC, VAULT, amount);
        _manage2(
            "approveDepositAsset",
            WBTC,
            abi.encodeCall(IERC20.approve, (LIQUID, amount)),
            "deposit",
            LIQUID_TELLER,
            abi.encodeCall(ITeller.deposit, (WBTC, amount, 0))
        );
        shares = IERC20(LIQUID).balanceOf(VAULT);
        vm.recordLogs();
        _manage2(
            "approveHop0",
            LIQUID,
            abi.encodeCall(IERC20.approve, (LIQUID_QUEUE, shares)),
            "requestHop0",
            LIQUID_QUEUE,
            abi.encodeCall(IQueue.requestOnChainWithdraw, (EBTC, uint128(shares), 1, 259200))
        );
        OnChainWithdraw memory stale = _requested(LIQUID_QUEUE);
        vm.warp(uint256(stale.creationTime) + stale.secondsToMaturity + stale.secondsToDeadline + 1);
        vm.recordLogs();
        _manage1("replaceHop0", LIQUID_QUEUE, abi.encodeCall(IQueue.replaceOnChainWithdraw, (stale, 1, 604800)));
        OnChainWithdraw memory renewed = _requested(LIQUID_QUEUE);
        require(renewed.amountOfShares == stale.amountOfShares && renewed.user == VAULT, "replace");
        console.log("replaced: nonce %s -> %s", stale.nonce, renewed.nonce);

        console.log("=== 7. cancel returns the shares to the vault");
        _manage1("cancelHop0", LIQUID_QUEUE, abi.encodeCall(IQueue.cancelOnChainWithdraw, (renewed)));
        require(IERC20(LIQUID).balanceOf(VAULT) == shares, "cancel");

        console.log("=== 8. what the strategist cannot do");
        // liquidBTC straight to WBTC: no leaf (and the queue has WBTC withdraws off)
        _expectManageRevert(
            "requestHop0", LIQUID_QUEUE, abi.encodeCall(IQueue.requestOnChainWithdraw, (WBTC, uint128(shares), 1, 604800))
        );
        // approving WBTC to the teller instead of the vault: no leaf
        _expectManageRevert("approveDepositAsset", WBTC, abi.encodeCall(IERC20.approve, (LIQUID_TELLER, 1)));
        // cancelling someone else's request: the decoder returns that user, so the proof fails
        OnChainWithdraw memory other = renewed;
        other.user = address(0xBEEF);
        _expectManageRevert("cancelHop0", LIQUID_QUEUE, abi.encodeCall(IQueue.cancelOnChainWithdraw, (other)));
        console.log("rehearsal passed");
    }

    // ===================================== HELPERS =====================================

    function _proof(string memory name) internal view returns (bytes32[] memory) {
        return vm.parseJsonBytes32Array(proofs, string.concat(".proofs.", name));
    }

    function _manage1(string memory leaf, address target, bytes memory data) internal {
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = _proof(leaf);
        address[] memory d = new address[](1);
        d[0] = decoder;
        address[] memory t = new address[](1);
        t[0] = target;
        bytes[] memory c = new bytes[](1);
        c[0] = data;
        vm.prank(STRATEGIST);
        IManager(MANAGER).manageVaultWithMerkleVerification(p, d, t, c, new uint256[](1));
    }

    function _manage2(
        string memory leaf0,
        address target0,
        bytes memory data0,
        string memory leaf1,
        address target1,
        bytes memory data1
    ) internal {
        bytes32[][] memory p = new bytes32[][](2);
        p[0] = _proof(leaf0);
        p[1] = _proof(leaf1);
        address[] memory d = new address[](2);
        d[0] = decoder;
        d[1] = decoder;
        address[] memory t = new address[](2);
        t[0] = target0;
        t[1] = target1;
        bytes[] memory c = new bytes[](2);
        c[0] = data0;
        c[1] = data1;
        vm.prank(STRATEGIST);
        IManager(MANAGER).manageVaultWithMerkleVerification(p, d, t, c, new uint256[](2));
    }

    function _expectManageRevert(string memory leaf, address target, bytes memory data) internal {
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = _proof(leaf);
        address[] memory d = new address[](1);
        d[0] = decoder;
        address[] memory t = new address[](1);
        t[0] = target;
        bytes[] memory c = new bytes[](1);
        c[0] = data;
        vm.prank(STRATEGIST);
        try IManager(MANAGER).manageVaultWithMerkleVerification(p, d, t, c, new uint256[](1)) {
            revert("the manager let it through");
        } catch {
            console.log("  reverted, as it should");
        }
    }

    /// The vault's request in the logs recorded since vm.recordLogs().
    function _requested(address queue) internal returns (OnChainWithdraw memory r) {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            VmSafe.Log memory l = logs[i - 1];
            if (l.emitter != queue || l.topics[0] != REQUESTED) continue;
            if (address(uint160(uint256(l.topics[2]))) != VAULT) continue;
            r.user = VAULT;
            r.assetOut = address(uint160(uint256(l.topics[3])));
            (r.nonce, r.amountOfShares, r.amountOfAssets, r.creationTime, r.secondsToMaturity, r.secondsToDeadline) =
                abi.decode(l.data, (uint96, uint128, uint128, uint40, uint24, uint24));
            require(keccak256(abi.encode(r)) == l.topics[1], "request id");
            return r;
        }
        revert("no request from the vault");
    }

    /// Fill a request as ether.fi's BoringSolver does, with the asset handed to the solver.
    function _solve(address queue, address solver, address asset, OnChainWithdraw memory r) internal {
        _give(asset, solver, r.amountOfAssets);
        vm.startPrank(solver);
        IERC20(asset).approve(queue, r.amountOfAssets);
        OnChainWithdraw[] memory rs = new OnChainWithdraw[](1);
        rs[0] = r;
        IQueue(queue).solveOnChainWithdraws(rs, "", solver);
        vm.stopPrank();
    }

    function _give(address token, address to, uint256 amount) internal {
        deal(token, to, IERC20(token).balanceOf(to) + amount);
    }
}

struct OnChainWithdraw {
    uint96 nonce;
    address user;
    address assetOut;
    uint128 amountOfShares;
    uint128 amountOfAssets;
    uint40 creationTime;
    uint24 secondsToMaturity;
    uint24 secondsToDeadline;
}

interface IManager {
    function setManageRoot(address strategist, bytes32 root) external;
    function manageRoot(address strategist) external view returns (bytes32);
    function manageVaultWithMerkleVerification(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values
    ) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface ITeller {
    function deposit(address depositAsset, uint256 depositAmount, uint256 minimumMint) external returns (uint256);
}

interface IAccountant {
    function getRateInQuoteSafe(address quote) external view returns (uint256);
}

interface IQueue {
    function requestOnChainWithdraw(address assetOut, uint128 amountOfShares, uint16 discount, uint24 secondsToDeadline)
        external
        returns (bytes32);
    function cancelOnChainWithdraw(OnChainWithdraw memory request) external returns (bytes32);
    function replaceOnChainWithdraw(OnChainWithdraw memory oldRequest, uint16 discount, uint24 secondsToDeadline)
        external
        returns (bytes32, bytes32);
    function solveOnChainWithdraws(OnChainWithdraw[] calldata requests, bytes calldata solveData, address solver)
        external;
}
