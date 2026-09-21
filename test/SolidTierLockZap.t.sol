// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {SolidTierLock} from "src/solid-rewards/SolidTierLock.sol";
import {SolidTierLockZap} from "src/solid-rewards/SolidTierLockZap.sol";
import {MockMintableERC20} from "test/mocks/MockMintableERC20.sol";
import {MockRateAccountant} from "test/mocks/MockRateAccountant.sol";
import {MockTeller} from "test/mocks/MockTeller.sol";
import {MockVaultShare} from "test/mocks/MockVaultShare.sol";
import {MockWrappedNative} from "test/mocks/MockWrappedNative.sol";

contract SolidTierLockZapTest is Test {
    uint64 internal constant YEAR = 365 days;
    /// @dev 1.25 FUSE per share. Above par so a missing rate conversion shows up.
    uint256 internal constant RATE = 1.25e18;
    uint8 internal constant ZAP_ROLE = 7;
    /**
     * @dev A copy of the zap's own sentinel, rather than reading `zap.NATIVE()`
     * at each call site. That read is a call of its own, and it would consume
     * the `prank` or `expectRevert` meant for the zap on the line below it —
     * which is how six of these tests first passed for the wrong reason.
     */
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    SolidTierLock internal lockContract;
    SolidTierLockZap internal zap;
    RolesAuthority internal authority;
    MockVaultShare internal share;
    MockWrappedNative internal wfuse;
    MockTeller internal teller;
    MockRateAccountant internal accountant;

    address internal alice = address(0xA11CE);

    function setUp() external {
        share = new MockVaultShare();
        wfuse = new MockWrappedNative();
        teller = new MockTeller(address(share), address(wfuse), RATE);
        accountant = new MockRateAccountant(RATE);

        lockContract = new SolidTierLock(address(this), address(share), address(accountant), YEAR, 1e18);
        zap = new SolidTierLockZap(address(this), address(lockContract), address(teller));

        // `lockFor` is restricted, so the zap has to be given the capability
        // explicitly. This mirrors the deployment: one role, one capability,
        // one holder.
        authority = new RolesAuthority(address(this), Authority(address(0)));
        authority.setRoleCapability(ZAP_ROLE, address(lockContract), SolidTierLock.lockFor.selector, true);
        authority.setUserRole(address(zap), ZAP_ROLE, true);
        lockContract.setAuthority(authority);

        share.mint(alice, 100_000e18);
        wfuse.deposit{value: 0}();
        vm.deal(alice, 1_000_000e18);
        vm.deal(address(this), 1_000_000e18);

        vm.startPrank(alice);
        share.approve(address(zap), type(uint256).max);
        wfuse.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @dev Mint WFUSE to an account, the way a wrapper does.
     */
    function _giveWfuse(address to, uint256 amount) internal {
        vm.deal(address(this), amount);
        wfuse.deposit{value: amount}();
        wfuse.transfer(to, amount);
    }

    //============================== NATIVE ===============================

    function testZapsNativeIntoALockedPosition() external {
        uint256 amount = 50_000e18;
        uint256 expectedShares = (amount * 1e18) / RATE;

        vm.prank(alice);
        uint256 shares = zap.zapAndLock{value: amount}(NATIVE, amount, 0);

        assertEq(shares, expectedShares, "shares are the deposit at the vault's rate");
        assertEq(lockContract.lockedSharesOf(alice), expectedShares, "credited to the caller, not the zap");
        assertEq(lockContract.lockedSharesOf(address(zap)), 0, "the zap holds no position of its own");
        assertEq(share.balanceOf(address(zap)), 0, "the zap keeps nothing");
        assertEq(address(zap).balance, 0, "and no native either");
    }

    /**
     * The whole point: the position is the user's, and the lock's own rule —
     * shares return only to the account that holds the record — still applies.
     */
    function testZappedPositionReturnsToTheUserAndNobodyElse() external {
        vm.prank(alice);
        zap.zapAndLock{value: 50_000e18}(NATIVE, 50_000e18, 0);

        uint256 locked = lockContract.lockedSharesOf(alice);
        skip(YEAR + 1);

        // Called by a stranger, on Alice's behalf — which is how Solid returns
        // matured positions — and the shares land with Alice.
        lockContract.withdrawFor(alice);

        assertEq(share.balanceOf(alice), 100_000e18 + locked, "shares came back to the user");
        assertEq(lockContract.lockedSharesOf(alice), 0, "position closed");
    }

    function testNativeValueMustMatchTheAmountAskedFor() external {
        vm.expectRevert(
            abi.encodeWithSelector(SolidTierLockZap.SolidTierLockZap__NativeValueMismatch.selector, 50_000e18, 1e18)
        );
        vm.prank(alice);
        zap.zapAndLock{value: 1e18}(NATIVE, 50_000e18, 0);
    }

    //============================== ERC-20 ===============================

    function testZapsWrappedNativeIntoALockedPosition() external {
        uint256 amount = 40_000e18;
        _giveWfuse(alice, amount);
        uint256 expectedShares = (amount * 1e18) / RATE;

        vm.prank(alice);
        uint256 shares = zap.zapAndLock(address(wfuse), amount, 0);

        assertEq(shares, expectedShares, "wrapped deposits price the same as native");
        assertEq(lockContract.lockedSharesOf(alice), expectedShares, "credited to the caller");
        assertEq(wfuse.balanceOf(address(zap)), 0, "no deposit asset left behind");
        assertEq(wfuse.allowance(address(zap), teller.vault()), 0, "and no standing approval");
    }

    /**
     * An ERC-20 deposit must not also carry value — that is two deposits in one call.
     */
    function testErc20ZapRejectsNativeValue() external {
        _giveWfuse(alice, 1_000e18);

        vm.expectRevert(SolidTierLockZap.SolidTierLockZap__UnexpectedNativeValue.selector);
        vm.prank(alice);
        zap.zapAndLock{value: 1e18}(address(wfuse), 1_000e18, 0);
    }

    //============================== SHARES ===============================

    function testZapsSharesStraightIntoTheLock() external {
        uint256 amount = 30_000e18;

        vm.prank(alice);
        uint256 shares = zap.zapAndLock(address(share), amount, 0);

        assertEq(shares, amount, "shares are locked one for one, with no Teller involved");
        assertEq(lockContract.lockedSharesOf(alice), amount, "credited to the caller");
        assertEq(share.balanceOf(alice), 100_000e18 - amount, "and taken from them");
    }

    //============================== SLIPPAGE ===============================

    /**
     * The bound exists because the rate moves between the app quoting a share
     * count and the transaction landing. A user asking for a tier's worth of
     * shares must not be handed fewer and locked in for a year regardless.
     */
    function testRefusesToLockFewerSharesThanAsked() external {
        uint256 amount = 50_000e18;
        uint256 atQuote = (amount * 1e18) / RATE;

        // The rate ticks up — the same FUSE now buys fewer shares.
        teller.setRate(RATE * 2);

        vm.expectRevert();
        vm.prank(alice);
        zap.zapAndLock{value: amount}(NATIVE, amount, atQuote);
    }

    function testZeroIsNotAnAmount() external {
        vm.expectRevert(SolidTierLockZap.SolidTierLockZap__ZeroAmount.selector);
        vm.prank(alice);
        zap.zapAndLock(address(share), 0, 0);
    }

    //============================== AUTHORITY ===============================

    /**
     * `lockFor` unrestricted would let anyone fill a stranger's lock list with
     * dust and block the upgrade they were trying to make.
     */
    function testLockForIsRestricted() external {
        share.mint(alice, 1e18);
        vm.prank(alice);
        share.approve(address(lockContract), type(uint256).max);

        vm.expectRevert("UNAUTHORIZED");
        vm.prank(alice);
        lockContract.lockFor(alice, 1e18);
    }

    /**
     * Revoking the role stops new zaps and touches no existing position.
     */
    function testRevokingTheZapsRoleStopsItLocking() external {
        vm.prank(alice);
        zap.zapAndLock{value: 50_000e18}(NATIVE, 50_000e18, 0);
        uint256 locked = lockContract.lockedSharesOf(alice);

        authority.setUserRole(address(zap), ZAP_ROLE, false);

        vm.expectRevert("UNAUTHORIZED");
        vm.prank(alice);
        zap.zapAndLock{value: 1_000e18}(NATIVE, 1_000e18, 0);

        assertEq(lockContract.lockedSharesOf(alice), locked, "the position already taken is untouched");
    }

    /**
     * A zap wired to a Teller that mints a different share than the lock
     * escrows would deposit successfully and then be unable to lock, stranding
     * the user's funds in the periphery. It has to fail at deployment instead.
     */
    function testRefusesATellerForADifferentVault() external {
        MockVaultShare otherShare = new MockVaultShare();
        MockTeller otherTeller = new MockTeller(address(otherShare), address(wfuse), RATE);

        vm.expectRevert(SolidTierLockZap.SolidTierLockZap__TellerMismatch.selector);
        new SolidTierLockZap(address(this), address(lockContract), address(otherTeller));
    }

    function testRefusesCodelessConstructorArguments() external {
        vm.expectRevert(SolidTierLockZap.SolidTierLockZap__InvalidAddress.selector);
        new SolidTierLockZap(address(this), address(0xdead), address(teller));

        vm.expectRevert(SolidTierLockZap.SolidTierLockZap__InvalidAddress.selector);
        new SolidTierLockZap(address(0), address(lockContract), address(teller));
    }

    //============================== RESCUE ===============================

    /**
     * Only a donation can ever be here, and without this it would be stuck.
     */
    function testRescueOfTokensSentHereByMistake() external {
        MockMintableERC20 stray = new MockMintableERC20("Stray", "STRAY", 18);
        stray.mint(address(zap), 500e18);

        zap.rescue(ERC20(address(stray)), address(this), 500e18);

        assertEq(stray.balanceOf(address(this)), 500e18, "recovered");
        assertEq(stray.balanceOf(address(zap)), 0, "and none left");
    }

    function testRescueIsRestricted() external {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(alice);
        zap.rescue(ERC20(address(share)), alice, 1);

        vm.expectRevert("UNAUTHORIZED");
        vm.prank(alice);
        zap.rescueNative(alice, 1);
    }

    /**
     * A donation sitting in the zap must not be counted towards the next
     * caller's lock — the balance is read as a delta for exactly this reason.
     */
    function testADonationIsNotLockedForTheNextCaller() external {
        share.mint(address(zap), 12_345e18);

        uint256 amount = 50_000e18;
        vm.prank(alice);
        uint256 shares = zap.zapAndLock{value: amount}(NATIVE, amount, 0);

        assertEq(shares, (amount * 1e18) / RATE, "only what this call minted");
        assertEq(share.balanceOf(address(zap)), 12_345e18, "the donation is untouched");
    }

    //============================== TOP-UP ===============================

    /**
     * A second zap is a second lock, on the day it is made — the same rule a
     * direct `lock` follows, so a top-up cannot push out the date the earlier
     * shares come back.
     */
    function testASecondZapIsASecondLock() external {
        vm.prank(alice);
        zap.zapAndLock{value: 50_000e18}(NATIVE, 50_000e18, 0);

        skip(30 days);

        vm.prank(alice);
        zap.zapAndLock{value: 40_000e18}(NATIVE, 40_000e18, 0);

        SolidTierLock.Lock[] memory locks = lockContract.getLocks(alice);
        assertEq(locks.length, 2, "two commitments");
        assertEq(locks[0].unlocksAt + 30 days, locks[1].unlocksAt, "each dated from when it was made");
    }
}
