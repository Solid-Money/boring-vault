// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test, console2} from "@forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/oapp-evm-v2/contracts/oft/interfaces/IOFT.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

/**
 * @notice Fork tests of a fresh BridgePaymaster on a chain that sends into Fuse, against the live
 *         Stargate pools there: the same contract as on Fuse, configured the way
 *         script/fuse/BridgePaymasterToFuse.s.sol configures it.
 * @dev Each chain deploys the paymaster at a fixed address, registers its Stargate pools with the
 *      single route to Fuse, and runs a real `bridgeSend` per pool, priced as the backend prices it.
 */
abstract contract BridgePaymasterToFuseTest is Test {
    using SafeERC20 for IERC20;

    uint32 internal constant FUSE = 30138;

    address internal deployer = makeAddr("deployer");
    uint256 internal signerKey = 0xA11CE;
    address internal signer;
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal user = makeAddr("userSafe");
    address internal recipient = makeAddr("userSafeOnFuse");
    uint256 internal nextNonce = 1;

    BridgePaymaster internal paymaster;

    /// @dev Per chain.
    function _rpc() internal view virtual returns (string memory);
    function _pools() internal pure virtual returns (address[] memory);
    function _unit() internal pure virtual returns (uint256);

    function setUp() public virtual {
        vm.createSelectFork(_rpc());
        signer = vm.addr(signerKey);

        address implementation = address(new BridgePaymaster());
        paymaster = BridgePaymaster(
            payable(address(new ERC1967Proxy(implementation, abi.encodeCall(BridgePaymaster.initialize, (deployer)))))
        );

        address[] memory pools = _pools();
        vm.startPrank(deployer);
        paymaster.initializeV2(signer, feeRecipient, 1 ether);
        for (uint256 i; i < pools.length; i++) {
            paymaster.setTarget(pools[i], BridgePaymaster.TargetKind.STARGATE_OFT, 5 * _unit());
            paymaster.setMaxSponsoredAmount(pools[i], 10_000 * _unit());
            paymaster.setRoute(pools[i], FUSE, true);
        }
        vm.stopPrank();

        vm.deal(address(paymaster), 1 ether);
    }

    function test_bridgeSend_everyPoolToFuse() public {
        address[] memory pools = _pools();
        for (uint256 i; i < pools.length; i++) {
            _assertBridgeSend(pools[i], 100 * _unit());
        }
    }

    function test_bridgeSend_largeAmountToFuse() public {
        // Fuse's Stargate tokens are minted on arrival, so no path credit caps a big send.
        _assertBridgeSend(_pools()[0], 10_000 * _unit());
    }

    // ===================================== HELPERS =====================================

    function _assertBridgeSend(address pool, uint256 amount) internal {
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(pool, amount);
        IERC20 token = _fund(pool, amount);
        uint256 nativeBefore = address(paymaster).balance;
        uint256 feeBefore = token.balanceOf(feeRecipient);

        vm.prank(user);
        (uint256 nativeFee, bytes32 guid) = paymaster.bridgeSend(v, sig);

        console2.log("pool", pool, "native fee (wei):", nativeFee);
        assertTrue(guid != bytes32(0), "LayerZero guid");
        assertLe(nativeFee, v.maxNativeFee, "native fee within voucher");
        assertEq(token.balanceOf(user), 0, "user debited the full amount");
        assertEq(token.balanceOf(feeRecipient), feeBefore + v.feeLD, "fee kept in token");
        assertEq(token.balanceOf(address(paymaster)), 0, "nothing left on paymaster");
        assertEq(address(paymaster).balance, nativeBefore - nativeFee, "paymaster fronts exactly the fee");
        assertEq(token.allowance(address(paymaster), pool), 0, "approval reset");
    }

    /// @dev Priced the way the backend prices it: quote the bare send, 10% headroom on the native
    ///      fee, and the recipient gets at least what Stargate quotes. The token fee is a stand-in.
    function _signedVoucher(address pool, uint256 amount)
        internal
        returns (BridgePaymaster.SendVoucher memory v, bytes memory sig)
    {
        v.from = user;
        v.oft = pool;
        v.dstEid = FUSE;
        v.to = recipient;
        v.amountLD = amount;
        v.feeLD = _unit() * 14 / 10;
        v.nonce = nextNonce++;
        v.deadline = uint64(block.timestamp + 10 minutes);

        SendParam memory p = SendParam(FUSE, bytes32(uint256(uint160(recipient))), amount - v.feeLD, 0, "", "", "");
        uint256 nativeFee = IOFT(pool).quoteSend(p, false).nativeFee;
        v.maxNativeFee = nativeFee + nativeFee / 10;
        (,, OFTReceipt memory receipt) = IOFT(pool).quoteOFT(p);
        v.minAmountLD = receipt.amountReceivedLD;

        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(signerKey, paymaster.hashVoucher(v));
        sig = abi.encodePacked(r, s, sv);
    }

    function _fund(address pool, uint256 amount) internal returns (IERC20 token) {
        token = IERC20(IOFT(pool).token());
        deal(address(token), user, amount);
        // Ethereum's USDT returns nothing from approve, which the IERC20 interface would reject.
        vm.prank(user);
        token.forceApprove(address(paymaster), type(uint256).max);
    }
}

/**
 * @notice Base: the Stargate USDC pool (no USDT pool exists on Base).
 *
 * Run with: forge test --match-path test/fuse/BridgePaymasterToFuse.t.sol
 *           (forks BASE_RPC_URL, ETHEREUM_RPC_URL and BNB_RPC_URL, defaulting to public nodes)
 */
contract BridgePaymasterToFuseBaseTest is BridgePaymasterToFuseTest {
    function _rpc() internal view override returns (string memory) {
        return vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com"));
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0x27a16dc786820B16E5c9028b75B99F6f604b5d26;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e6;
    }
}

/// @notice Ethereum: the Stargate USDC and USDT pools.
contract BridgePaymasterToFuseEthereumTest is BridgePaymasterToFuseTest {
    function _rpc() internal view override returns (string memory) {
        return vm.envOr("ETHEREUM_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = 0xc026395860Db2d07ee33e05fE50ed7bD583189C7;
        pools[1] = 0x933597a323Eb81cAe705C5bC29985172fd5A3973;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e6;
    }
}

/**
 * @notice BNB Chain: the Stargate USDC and USDT pools, both 18 decimals against Stargate's 6
 *         shared ones.
 * @dev A pool only sends whole 6-decimal units and pulls just that much, so any remainder of
 *      `amountLD - feeLD` below 1e12 stays on the paymaster. The backend must round both amounts
 *      on this chain; the second test shows what happens if it doesn't.
 */
contract BridgePaymasterToFuseBnbTest is BridgePaymasterToFuseTest {
    function _rpc() internal view override returns (string memory) {
        return vm.envOr("BNB_RPC_URL", string("https://bsc-rpc.publicnode.com"));
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = 0x962Bd449E630b0d928f308Ce63f1A21F02576057;
        pools[1] = 0x138EB30f73BC423c6455C53df6D89CB01d9eBc63;
    }

    function _unit() internal pure override returns (uint256) {
        return 1e18;
    }

    function test_bridgeSend_unroundedAmountLeavesDustOnPaymaster() public {
        address pool = _pools()[1];
        uint256 amount = 100e18 + 123_456;
        (BridgePaymaster.SendVoucher memory v, bytes memory sig) = _signedVoucher(pool, amount);
        IERC20 token = _fund(pool, amount);

        vm.prank(user);
        paymaster.bridgeSend(v, sig);

        assertEq(token.balanceOf(address(paymaster)), 123_456, "sub-unit dust stays on the paymaster");
    }
}
