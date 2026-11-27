// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Script, console} from "@forge-std/Script.sol";
import {SolidSoETHDecoderAndSanitizer} from
    "src/base/DecodersAndSanitizers/Solid/SolidSoETHDecoderAndSanitizer.sol";
import {DecoderCustomTypes} from "src/interfaces/DecoderCustomTypes.sol";

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

interface IStargatePool {
    function quoteSend(DecoderCustomTypes.SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (DecoderCustomTypes.MessagingFee memory);
    function send(
        DecoderCustomTypes.SendParam calldata sendParam,
        DecoderCustomTypes.MessagingFee calldata fee,
        address refundAddress
    ) external payable;
}

interface IWETH {
    function withdraw(uint256) external;
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
}

/**
 * @notice soETH on Base: the strategist's first manage root, so the Base vault's
 *         idle WETH can go to the Ethereum vault over Stargate's native ETH pool.
 *
 *  1. deploy:   SolidSoETHDecoderAndSanitizer on Base through the CREATE2 factory,
 *               at DECODER (the build is checked against it first). Any account
 *               can send it; the address depends only on this build.
 *  2. proofs:   solid-backend `scripts/soeth-base-stargate-proofs.ts out.json`
 *               (root + one proof per leaf, built from the strategist's own tree).
 *  3. rehearse: on a Base fork, sets that root as the Safe and runs the bridge
 *               call the strategist makes (unwrap WETH, Stargate send), then the
 *               wrap of leftover native.
 *  4. batch:    writes the Base Safe 0x5Eb1 batch: setManageRoot(strategist, root).
 *
 *   SOETH_BASE_STEP=deploy   forge script script/soETH/base/SoEthBaseStargate.s.sol \
 *       --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY [--broadcast]
 *   SOETH_BASE_STEP=rehearse SOETH_BASE_PROOFS=out.json forge script ... --rpc-url $BASE_RPC_URL
 *   SOETH_BASE_STEP=batch    SOETH_BASE_PROOFS=out.json forge script ... --rpc-url $BASE_RPC_URL
 */
contract SoEthBaseStargate is Script {
    bytes32 internal constant SALT = keccak256("solid.soETH.base.SolidSoETHDecoderAndSanitizer.v1");
    // Where SALT and this build of the decoder land; solid-backend's
    // soETHDecoderAndSanitizer[BASE] defaults to it.
    address internal constant DECODER = 0x134F60B6DAfad149D1a7579e6fd6384736bc8d5d;

    address internal constant SAFE = 0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3;
    address internal constant STRATEGIST = 0x6f3334EC6355eD6f70100Cd1Cd6736505cd0F9b5;
    address internal constant MANAGER = 0x755B05025a369f314E64D2a41d652CC2C648a4C8;
    address internal constant VAULT = 0x9b0e0EFA48C00eBEeA845AeA197F0bB71529D235;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    // Stargate V2 StargatePoolNative on Base; its Ethereum peer is 0x77b2…7931
    address internal constant STARGATE_NATIVE_POOL = 0xdc181Bd607330aeeBEF6ea62e03e5e1Fb4B6F7C7;
    address internal constant ETHEREUM_VAULT = 0xf9039d4f49686F34936b6937D13bBbe413f910c4;
    uint32 internal constant ETHEREUM_EID = 30101;

    string internal proofs;

    function run() external {
        require(block.chainid == 8453, "Base only");
        bytes32 step = keccak256(bytes(vm.envString("SOETH_BASE_STEP")));
        if (step == keccak256("predict")) return _predict();
        if (step == keccak256("deploy")) return _deploy();
        proofs = vm.readFile(vm.envString("SOETH_BASE_PROOFS"));
        require(vm.parseJsonAddress(proofs, ".decoder") == DECODER, "proofs are for another decoder");
        require(vm.parseJsonAddress(proofs, ".vault") == VAULT, "proofs are for another vault");
        if (step == keccak256("rehearse")) return _rehearse();
        if (step == keccak256("batch")) return _batch();
        revert("SOETH_BASE_STEP: predict | deploy | rehearse | batch");
    }

    // ===================================== DEPLOY =====================================

    function _predicted() internal pure returns (address) {
        return vm.computeCreate2Address(
            SALT, keccak256(type(SolidSoETHDecoderAndSanitizer).creationCode), CREATE2_FACTORY
        );
    }

    function _predict() internal pure {
        console.log("SolidSoETHDecoderAndSanitizer lands at", _predicted());
    }

    function _deploy() internal {
        address predicted = _predicted();
        require(predicted == DECODER, "this build of the decoder lands elsewhere than DECODER");
        if (predicted.code.length == 0) {
            vm.startBroadcast();
            new SolidSoETHDecoderAndSanitizer{salt: SALT}();
            vm.stopBroadcast();
        } else {
            console.log("already deployed");
        }
        require(
            predicted.codehash == keccak256(type(SolidSoETHDecoderAndSanitizer).runtimeCode), "decoder code differs"
        );
        console.log("SolidSoETHDecoderAndSanitizer", predicted);
    }

    // ===================================== REHEARSE =====================================

    function _rehearse() internal {
        if (DECODER.code.length == 0) {
            vm.etch(DECODER, type(SolidSoETHDecoderAndSanitizer).runtimeCode);
            console.log("decoder not deployed; etched at %s for the rehearsal", DECODER);
        }
        bytes32 root = vm.parseJsonBytes32(proofs, ".root");
        vm.prank(SAFE);
        IManager(MANAGER).setManageRoot(STRATEGIST, root);

        uint256 wethStart = IWETH(WETH).balanceOf(VAULT);
        uint256 nativeStart = VAULT.balance;
        require(wethStart >= 1e18, "rehearsal bridges 1 WETH; the vault holds less");
        console.log("vault WETH %s, native %s", wethStart, nativeStart);

        // What utils/stargate.ts bridgeNativeToChain sends: 1 WETH, its fee paid
        // from the vault's native balance (topped up by the strategist if short)
        uint256 amount = 1e18;
        DecoderCustomTypes.SendParam memory sp = DecoderCustomTypes.SendParam({
            dstEid: ETHEREUM_EID,
            to: bytes32(uint256(uint160(ETHEREUM_VAULT))),
            amountLD: amount,
            minAmountLD: amount * 99 / 100,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        DecoderCustomTypes.MessagingFee memory fee = IStargatePool(STARGATE_NATIVE_POOL).quoteSend(sp, false);
        if (nativeStart < fee.nativeFee) vm.deal(VAULT, fee.nativeFee);
        uint256 nativeBefore = VAULT.balance;

        bytes32[][] memory p = new bytes32[][](2);
        p[0] = _proof("withdrawWETH");
        p[1] = _proof("stargateSend");
        address[] memory d = new address[](2);
        d[0] = DECODER;
        d[1] = DECODER;
        address[] memory t = new address[](2);
        t[0] = WETH;
        t[1] = STARGATE_NATIVE_POOL;
        bytes[] memory c = new bytes[](2);
        c[0] = abi.encodeCall(IWETH.withdraw, (amount));
        c[1] = abi.encodeCall(IStargatePool.send, (sp, fee, VAULT));
        uint256[] memory v = new uint256[](2);
        v[1] = amount + fee.nativeFee;
        vm.prank(STRATEGIST);
        IManager(MANAGER).manageVaultWithMerkleVerification(p, d, t, c, v);

        require(IWETH(WETH).balanceOf(VAULT) == wethStart - amount, "WETH out != amount");
        require(VAULT.balance == nativeBefore - fee.nativeFee, "native out != fee");
        console.log("bridged %s WETH, fee %s wei paid from the vault", amount, fee.nativeFee);

        // A send to anywhere else fails its proof: same leaf shape, other recipient
        _expectProofRefused(p, d, t, c, v, bytes32(uint256(uint160(STRATEGIST))), sp, fee);

        // Wrap whatever native is left of the Nov 26 gas top-up after the fee
        uint256 leftover = VAULT.balance;
        bytes32[][] memory wp = new bytes32[][](1);
        wp[0] = _proof("depositWETH");
        address[] memory wd = new address[](1);
        wd[0] = DECODER;
        address[] memory wt = new address[](1);
        wt[0] = WETH;
        bytes[] memory wc = new bytes[](1);
        wc[0] = abi.encodeCall(IWETH.deposit, ());
        uint256[] memory wv = new uint256[](1);
        wv[0] = leftover;
        uint256 wethBeforeWrap = IWETH(WETH).balanceOf(VAULT);
        vm.prank(STRATEGIST);
        IManager(MANAGER).manageVaultWithMerkleVerification(wp, wd, wt, wc, wv);
        require(IWETH(WETH).balanceOf(VAULT) == wethBeforeWrap + leftover, "wrap");
        console.log("wrapped %s wei of leftover native", leftover);
        console.log("rehearsal passed");
    }

    function _expectProofRefused(
        bytes32[][] memory p,
        address[] memory d,
        address[] memory t,
        bytes[] memory c,
        uint256[] memory v,
        bytes32 to,
        DecoderCustomTypes.SendParam memory sp,
        DecoderCustomTypes.MessagingFee memory fee
    ) internal {
        sp.to = to;
        c[1] = abi.encodeCall(IStargatePool.send, (sp, fee, VAULT));
        vm.prank(STRATEGIST);
        try IManager(MANAGER).manageVaultWithMerkleVerification(p, d, t, c, v) {
            revert("a send to another recipient went through");
        } catch (bytes memory reason) {
            require(
                bytes4(reason) == ManagerWithMerkleVerification__FailedToVerifyManageProof.selector, "refused, but not by the proof check"
            );
            console.log("send to another recipient refused by the proof check");
        }
    }

    error ManagerWithMerkleVerification__FailedToVerifyManageProof(address target, bytes targetData, uint256 value);

    function _proof(string memory name) internal view returns (bytes32[] memory) {
        return vm.parseJsonBytes32Array(proofs, string.concat(".proofs.", name));
    }

    // ===================================== BATCH =====================================

    function _batch() internal {
        bytes32 root = vm.parseJsonBytes32(proofs, ".root");
        bytes memory data = abi.encodeCall(IManager.setManageRoot, (STRATEGIST, root));
        vm.prank(SAFE);
        (bool ok,) = MANAGER.call(data);
        require(ok && IManager(MANAGER).manageRoot(STRATEGIST) == root, "setManageRoot");

        string memory path = "deployments/safe-batches/base-soeth-stargate-root.json";
        string memory json = string.concat(
            '{\n  "version": "1.0",\n  "chainId": "8453",\n  "createdAt": ',
            vm.toString(block.timestamp * 1000),
            ',\n  "meta": {\n    "name": "Base soETH: strategist root with the Stargate bridge to Ethereum",\n',
            '    "description": "Manager 0x755B setManageRoot(strategist 0x6f33, ',
            vm.toString(root),
            "): unwrap WETH and send it over Stargate's native ETH pool to the Ethereum soETH vault, wrap native, claim fees. Decoder ",
            vm.toString(DECODER),
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
}
