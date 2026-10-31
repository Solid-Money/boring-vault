// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BridgePaymaster} from "src/fuse/BridgePaymaster.sol";

/**
 * @notice Fork test of `lifiCall` on Base against LI.FI's real diamond and Stargate: the live Base
 *         paymaster upgraded to this implementation, running LI.FI quotes fetched moments before.
 * @dev Quotes go stale within minutes, so they are fetched by script/fuse/lifi-sponsored-fixtures.sh
 *      and the fork is at Base's latest block. Without `LIFI_FIXTURES` the tests skip.
 *
 * Run with: script/fuse/lifi-sponsored-fixtures.sh && \
 *           LIFI_FIXTURES=cache/lifi-fixtures forge test --match-path test/fuse/BridgePaymasterLifiCallFork.t.sol
 *           (forks BASE_RPC_URL, defaulting to a public node)
 */
contract BridgePaymasterLifiCallForkTest is Test {
    BridgePaymaster internal constant PAYMASTER = BridgePaymaster(payable(0xC4F4bb4CD9C2098Dd1Eb11e0055FD0E212c967fc));
    address internal constant DIAMOND = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
    address internal constant UNI = 0xc3De830EA07524a0761646a6a4e4be0e114a3C83;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint32 internal constant FUSE_EID = 30138;

    /// @dev The receiver the fixtures were quoted for.
    address internal constant RECEIVER = 0x5Afe00000000000000000000000000000000bEeF;

    uint256 internal signerKey = 0xA11CE;
    string internal fixtures;

    event LifiCallSponsored(
        address indexed from,
        address indexed target,
        uint256 indexed nonce,
        address token,
        uint256 amount,
        uint256 nativeFee,
        bytes32 transactionId
    );

    function setUp() public {
        fixtures = vm.envOr("LIFI_FIXTURES", string(""));
        if (bytes(fixtures).length == 0) return;
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")));

        // The upgrade and configuration the owner would run, then a key of the test's own.
        address owner = PAYMASTER.owner();
        address implementation = address(new BridgePaymaster());
        vm.startPrank(owner);
        PAYMASTER.upgradeToAndCall(implementation, "");
        PAYMASTER.setTarget(DIAMOND, BridgePaymaster.TargetKind.LIFI_DIAMOND, 0);
        PAYMASTER.setRoute(DIAMOND, FUSE_EID, true);
        PAYMASTER.setMaxSponsoredAmount(DIAMOND, 0.005 ether);
        PAYMASTER.setVoucherSigner(vm.addr(signerKey));
        PAYMASTER.setDailyFeeBudget(0.05 ether);
        vm.stopPrank();
        vm.deal(address(PAYMASTER), 0.1 ether);
    }

    function test_uniToWfuse_swapsBridgesAndPaysTheFee() public {
        _run("uni-to-wfuse");
    }

    function test_usdcToFuseUsdc_bridgesAndPaysTheFee() public {
        _run("usdc-to-usdc");
    }

    function test_ethToFuseUsdc_userPaysTheirEthAndPaymasterTheFee() public {
        _run("eth-to-usdc");
    }

    struct Fixture {
        bytes data;
        address token;
        uint256 amount;
        uint256 fee;
    }

    struct Balances {
        uint256 native;
        uint256 uni;
        uint256 usdc;
    }

    function _run(string memory name) internal {
        if (bytes(fixtures).length == 0) vm.skip(true);
        Fixture memory f = _fixture(name);
        bool native = f.token == address(0);
        BridgePaymaster.LifiVoucher memory v = BridgePaymaster.LifiVoucher({
            from: RECEIVER,
            target: DIAMOND,
            token: f.token,
            amount: f.amount,
            dataHash: keccak256(f.data),
            nativeFee: f.fee,
            nonce: uint256(keccak256(bytes(name))),
            deadline: uint64(block.timestamp + 600)
        });
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(signerKey, PAYMASTER.hashLifiVoucher(v));
        Balances memory before = _paymasterBalances();

        vm.startPrank(RECEIVER);
        if (native) {
            vm.deal(RECEIVER, f.amount);
        } else {
            deal(f.token, RECEIVER, f.amount);
            IERC20(f.token).approve(address(PAYMASTER), f.amount);
        }
        PAYMASTER.lifiCall{value: native ? f.amount : 0}(v, f.data, abi.encodePacked(r, s, sv));
        vm.stopPrank();

        _assertSettled(f, before);
    }

    function _fixture(string memory name) internal view returns (Fixture memory f) {
        string memory json = vm.readFile(string.concat(fixtures, "/", name, ".json"));
        f.data = vm.parseJsonBytes(json, ".data");
        f.token = vm.parseJsonAddress(json, ".fromToken");
        f.amount = vm.parseUint(vm.parseJsonString(json, ".fromAmount"));
        uint256 value = vm.parseUint(vm.parseJsonString(json, ".value"));
        f.fee = f.token == address(0) ? value - f.amount : value;
    }

    function _paymasterBalances() internal view returns (Balances memory b) {
        b.native = address(PAYMASTER).balance;
        b.uni = IERC20(UNI).balanceOf(address(PAYMASTER));
        b.usdc = IERC20(USDC).balanceOf(address(PAYMASTER));
    }

    /// @dev The coin went into the route, whatever LI.FI left came back to the receiver, and the
    ///      paymaster paid at most the fee and kept none of the user's coins.
    function _assertSettled(Fixture memory f, Balances memory before) internal view {
        if (f.token == address(0)) assertLe(RECEIVER.balance, f.amount);
        else assertLe(IERC20(f.token).balanceOf(RECEIVER), f.amount);
        uint256 spent = before.native - address(PAYMASTER).balance;
        assertGt(spent, 0);
        assertLe(spent, f.fee);
        assertEq(IERC20(UNI).balanceOf(address(PAYMASTER)), before.uni);
        assertEq(IERC20(USDC).balanceOf(address(PAYMASTER)), before.usdc);
        assertEq(IERC20(USDC).allowance(address(PAYMASTER), DIAMOND), 0);
        if (f.token != address(0)) assertEq(IERC20(f.token).allowance(address(PAYMASTER), DIAMOND), 0);
        assertGe(PAYMASTER.feeSpentToday(), f.fee);
    }
}
