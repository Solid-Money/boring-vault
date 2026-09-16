// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {SolidTierLock} from "src/solid-rewards/SolidTierLock.sol";
import {MockMintableERC20} from "test/mocks/MockMintableERC20.sol";
import {MockRateAccountant} from "test/mocks/MockRateAccountant.sol";

contract SolidTierLockTest is Test {
    uint64 internal constant YEAR = 365 days;
    uint256 internal constant ONE = 1e18;

    SolidTierLock internal lockContract;
    MockMintableERC20 internal shares;
    MockRateAccountant internal accountant;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() external {
        shares = new MockMintableERC20("soFUSE", "soFUSE", 18);
        // 1.2 FUSE per share: a yield-bearing share is worth more than par, and
        // testing at par would hide a missing ONE_SHARE divisor.
        accountant = new MockRateAccountant(1.2e18);

        lockContract = new SolidTierLock(address(this), address(shares), address(accountant), YEAR, 1e18);

        shares.mint(alice, 1_000_000e18);
        shares.mint(bob, 1_000_000e18);

        vm.prank(alice);
        shares.approve(address(lockContract), type(uint256).max);
        vm.prank(bob);
        shares.approve(address(lockContract), type(uint256).max);
    }

    function _lock(address who, uint256 amount) internal returns (uint256 index) {
        vm.prank(who);
        return lockContract.lock(amount);
    }

    //============================== LOCKING ===============================

    function testLockMovesSharesAndRecordsTheTerm() external {
        uint256 balanceBefore = shares.balanceOf(alice);

        uint256 index = _lock(alice, 50_000e18);

        assertEq(index, 0, "first lock is index 0");
        assertEq(shares.balanceOf(alice), balanceBefore - 50_000e18, "shares left the account");
        assertEq(shares.balanceOf(address(lockContract)), 50_000e18, "shares are held by the lock");
        assertEq(lockContract.lockedSharesOf(alice), 50_000e18, "per-account total");
        assertEq(lockContract.totalLockedShares(), 50_000e18, "global total");

        SolidTierLock.Lock[] memory locks = lockContract.getLocks(alice);
        assertEq(locks.length, 1, "one open lock");
        assertEq(locks[0].shares, 50_000e18, "lock records the amount");
        assertEq(locks[0].lockedAt, uint64(block.timestamp), "lock records when");
        assertEq(locks[0].unlocksAt, uint64(block.timestamp) + YEAR, "lock records the term");
    }

    function testLockRejectsZeroAndDust() external {
        vm.expectRevert(SolidTierLock.SolidTierLock__ZeroAmount.selector);
        vm.prank(alice);
        lockContract.lock(0);

        vm.expectRevert(abi.encodeWithSelector(SolidTierLock.SolidTierLock__BelowMinimum.selector, 1, 1e18));
        vm.prank(alice);
        lockContract.lock(1);
    }

    function testLockRejectedOncePaused() external {
        lockContract.pause();

        vm.expectRevert(SolidTierLock.SolidTierLock__Paused.selector);
        vm.prank(alice);
        lockContract.lock(50_000e18);

        lockContract.unpause();
        _lock(alice, 50_000e18);
        assertEq(lockContract.lockedSharesOf(alice), 50_000e18, "unpausing restores locking");
    }

    function testLockCountIsBounded() external {
        uint256 max = lockContract.MAX_LOCKS_PER_ACCOUNT();

        for (uint256 i; i < max; ++i) {
            _lock(alice, 1e18);
        }

        vm.expectRevert(SolidTierLock.SolidTierLock__TooManyLocks.selector);
        vm.prank(alice);
        lockContract.lock(1e18);
    }

    //============================== WITHDRAWING ===============================

    function testCannotWithdrawBeforeTheTermIsUp() external {
        _lock(alice, 50_000e18);

        skip(YEAR - 1);

        vm.expectRevert(SolidTierLock.SolidTierLock__NothingMatured.selector);
        vm.prank(alice);
        lockContract.withdraw();
    }

    function testWithdrawReturnsSharesOnceMatured() external {
        _lock(alice, 50_000e18);
        uint256 balanceBefore = shares.balanceOf(alice);

        skip(YEAR);

        vm.prank(alice);
        uint256 withdrawn = lockContract.withdraw();

        assertEq(withdrawn, 50_000e18, "the whole lock came back");
        assertEq(shares.balanceOf(alice), balanceBefore + 50_000e18, "shares are back in the account");
        assertEq(lockContract.lockedSharesOf(alice), 0, "nothing left locked");
        assertEq(lockContract.totalLockedShares(), 0, "global total cleared");
        assertEq(lockContract.lockCountOf(alice), 0, "the lock is closed");
    }

    /**
     * The promise in the app is that FUSE unlocks automatically, which only
     * holds if somebody other than the user can do the unlocking — and it is
     * only safe because the shares can go nowhere but back to the owner.
     */
    function testAnyoneMayReturnAMaturedLockButOnlyToItsOwner() external {
        _lock(alice, 50_000e18);
        skip(YEAR);

        uint256 aliceBefore = shares.balanceOf(alice);
        uint256 bobBefore = shares.balanceOf(bob);

        vm.prank(bob);
        lockContract.withdrawFor(alice);

        assertEq(shares.balanceOf(alice), aliceBefore + 50_000e18, "the owner was paid");
        assertEq(shares.balanceOf(bob), bobBefore, "the caller was not");
    }

    function testWithdrawTakesOnlyTheMaturedLocks() external {
        _lock(alice, 10_000e18);
        skip(30 days);
        _lock(alice, 25_000e18);

        // Far enough for the first term but not the second.
        skip(YEAR - 30 days);

        vm.prank(alice);
        uint256 withdrawn = lockContract.withdraw();

        assertEq(withdrawn, 10_000e18, "only the older lock matured");
        assertEq(lockContract.lockedSharesOf(alice), 25_000e18, "the newer lock is untouched");
        assertEq(lockContract.lockCountOf(alice), 1, "one lock still open");

        skip(30 days);

        vm.prank(alice);
        assertEq(lockContract.withdraw(), 25_000e18, "the newer lock matures on its own date");
        assertEq(lockContract.lockedSharesOf(alice), 0, "nothing left");
    }

    /**
     * Closing a lock swaps the last entry into its slot, so a withdrawal that
     * matures a lock in the middle of the list has to leave the survivors
     * intact — this is the case a naive `delete` would corrupt.
     */
    function testClosingAMiddleLockKeepsTheOthers() external {
        _lock(alice, 1_000e18);
        skip(1 days);
        _lock(alice, 2_000e18);
        skip(1 days);
        _lock(alice, 3_000e18);

        // Matures the first two, leaves the third running.
        skip(YEAR - 1 days);

        vm.prank(alice);
        assertEq(lockContract.withdraw(), 3_000e18, "the two older locks came back");

        SolidTierLock.Lock[] memory locks = lockContract.getLocks(alice);
        assertEq(locks.length, 1, "one survivor");
        assertEq(locks[0].shares, 3_000e18, "and it is the newest one");
        assertEq(lockContract.lockedSharesOf(alice), 3_000e18, "accounting agrees");
    }

    /**
     * A pause is for a problem on our side. Refusing to give back money that is
     * already owed is not a response to one.
     */
    function testPauseNeverBlocksAWithdrawal() external {
        _lock(alice, 50_000e18);
        skip(YEAR);

        lockContract.pause();

        vm.prank(alice);
        assertEq(lockContract.withdraw(), 50_000e18, "a matured lock still comes back while paused");
    }

    //============================== TERMS ===============================

    /**
     * The one thing an admin key must not be able to do to money it does not
     * hold: reach back and lengthen a commitment already made.
     */
    function testChangingTheDurationCannotExtendAnExistingLock() external {
        _lock(alice, 50_000e18);
        uint64 unlocksAt = lockContract.getLocks(alice)[0].unlocksAt;

        lockContract.setLockDuration(4 * YEAR);

        assertEq(lockContract.getLocks(alice)[0].unlocksAt, unlocksAt, "the stored date did not move");

        skip(YEAR);
        vm.prank(alice);
        assertEq(lockContract.withdraw(), 50_000e18, "and it still matures on it");
    }

    function testDurationIsBounded() external {
        vm.expectRevert(SolidTierLock.SolidTierLock__ZeroDuration.selector);
        lockContract.setLockDuration(0);

        uint64 max = lockContract.MAX_LOCK_DURATION();
        vm.expectRevert(
            abi.encodeWithSelector(SolidTierLock.SolidTierLock__DurationTooLong.selector, max + 1, max)
        );
        lockContract.setLockDuration(max + 1);
    }

    //============================== VIEWS ===============================

    function testMaturedAndNextUnlockReadTheList() external {
        _lock(alice, 10_000e18);
        skip(10 days);
        _lock(alice, 20_000e18);

        assertEq(lockContract.maturedSharesOf(alice), 0, "nothing has matured yet");

        (uint64 unlocksAt, uint256 amount) = lockContract.nextUnlockOf(alice);
        assertEq(amount, 10_000e18, "the soonest tranche is the oldest lock");
        assertEq(unlocksAt, lockContract.getLocks(alice)[0].unlocksAt, "and its date");

        skip(YEAR - 10 days);
        assertEq(lockContract.maturedSharesOf(alice), 10_000e18, "the first lock is now due");

        (unlocksAt, amount) = lockContract.nextUnlockOf(alice);
        assertEq(amount, 20_000e18, "the next one is the second lock");
    }

    function testNextUnlockAggregatesLocksSharingADate() external {
        _lock(alice, 10_000e18);
        _lock(alice, 20_000e18);

        (uint64 unlocksAt, uint256 amount) = lockContract.nextUnlockOf(alice);
        assertEq(unlocksAt, uint64(block.timestamp) + YEAR, "both mature together");
        assertEq(amount, 30_000e18, "so both are reported");
    }

    function testLockedAssetsUsesTheRate() external {
        _lock(alice, 50_000e18);

        assertEq(lockContract.lockedAssetsOf(alice), 60_000e18, "50k shares at 1.2 is 60k FUSE");

        // The whole point of locking shares rather than the asset: the position
        // keeps earning, so the commitment only ever grows past its threshold.
        accountant.setRate(1.5e18);
        assertEq(lockContract.lockedAssetsOf(alice), 75_000e18, "a higher rate is worth more FUSE");
    }

    function testLockedAssetsSurvivesARateOutage() external {
        _lock(alice, 50_000e18);
        accountant.setShouldRevert(true);

        assertEq(lockContract.lockedAssetsOf(alice), 0, "a dead accountant reports 0 rather than reverting");

        skip(YEAR);
        vm.prank(alice);
        assertEq(lockContract.withdraw(), 50_000e18, "and never blocks a withdrawal");
    }

    function testLockedAssetsOfAnAccountWithNothing() external view {
        assertEq(lockContract.lockedAssetsOf(bob), 0, "no locks, no value");
    }

    //============================== ADMIN ===============================

    function testRescueCannotReachLockedShares() external {
        _lock(alice, 50_000e18);

        vm.expectRevert(SolidTierLock.SolidTierLock__CannotRescueLockedShares.selector);
        lockContract.rescue(ERC20(address(shares)), address(this), 1);

        // A stray transfer is not a lock, so it can be recovered.
        shares.mint(address(lockContract), 7e18);
        lockContract.rescue(ERC20(address(shares)), address(this), 7e18);
        assertEq(shares.balanceOf(address(this)), 7e18, "the surplus came out");

        skip(YEAR);
        vm.prank(alice);
        assertEq(lockContract.withdraw(), 50_000e18, "the lock is still whole");
    }

    function testRescueOfAnUnrelatedToken() external {
        MockMintableERC20 stray = new MockMintableERC20("Stray", "STRAY", 6);
        stray.mint(address(lockContract), 100e6);

        lockContract.rescue(ERC20(address(stray)), address(this), 100e6);

        assertEq(stray.balanceOf(address(this)), 100e6, "an unrelated token comes out freely");
    }

    function testAdminFunctionsAreGated() external {
        RolesAuthority authority = new RolesAuthority(address(this), Authority(address(0)));
        lockContract.setAuthority(authority);

        vm.startPrank(bob);
        vm.expectRevert("UNAUTHORIZED");
        lockContract.pause();

        vm.expectRevert("UNAUTHORIZED");
        lockContract.setLockDuration(30 days);

        vm.expectRevert("UNAUTHORIZED");
        lockContract.setMinLockShares(0);

        vm.expectRevert("UNAUTHORIZED");
        lockContract.rescue(ERC20(address(shares)), bob, 1);
        vm.stopPrank();
    }

    function testMinLockSharesIsConfigurable() external {
        lockContract.setMinLockShares(0);

        vm.prank(alice);
        lockContract.lock(1);

        assertEq(lockContract.lockedSharesOf(alice), 1, "the floor moved");
    }

    //============================== PROPERTIES ===============================

    function testFuzzLockThenWithdrawRoundTrips(uint128 amount, uint32 wait) external {
        amount = uint128(bound(amount, 1e18, 1_000_000e18));
        uint256 waitSeconds = bound(wait, 0, 4 * uint256(YEAR));

        uint256 balanceBefore = shares.balanceOf(alice);
        _lock(alice, amount);

        skip(waitSeconds);

        if (waitSeconds < YEAR) {
            vm.expectRevert(SolidTierLock.SolidTierLock__NothingMatured.selector);
            vm.prank(alice);
            lockContract.withdraw();
            return;
        }

        vm.prank(alice);
        assertEq(lockContract.withdraw(), amount, "exactly what went in comes out");
        assertEq(shares.balanceOf(alice), balanceBefore, "the account is whole again");
        assertEq(lockContract.totalLockedShares(), 0, "and nothing is left behind");
    }
}
