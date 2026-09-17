// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {SolidSubscriptionModule} from "src/solid-rewards/SolidSubscriptionModule.sol";
import {MockMintableERC20} from "test/mocks/MockMintableERC20.sol";
import {MockSafe} from "test/mocks/MockSafe.sol";

contract SolidSubscriptionModuleTest is Test {
    uint8 internal constant BILLER_ROLE = 7;

    /// @dev USDC has 6 decimals, so the plan price is 199_000000.
    uint128 internal constant PLAN_PRICE = 199e6;
    uint128 internal constant ORG_CEILING = 500e6;
    uint64 internal constant YEAR = 365 days;

    SolidSubscriptionModule internal module;
    RolesAuthority internal authority;
    MockMintableERC20 internal usdc;
    MockSafe internal safe;

    address internal treasury = address(0x7EA5);
    address internal biller = address(0xB111E2);
    address internal stranger = address(0x57A);

    function setUp() external {
        usdc = new MockMintableERC20("USD Coin", "USDC", 6);
        safe = new MockSafe();

        module = new SolidSubscriptionModule(address(this), address(usdc), treasury, ORG_CEILING);

        authority = new RolesAuthority(address(this), Authority(address(0)));
        authority.setRoleCapability(BILLER_ROLE, address(module), SolidSubscriptionModule.charge.selector, true);
        authority.setUserRole(biller, BILLER_ROLE, true);
        module.setAuthority(authority);

        usdc.mint(address(safe), 10_000e6);

        safe.enableModule(address(module));
        _subscribe(PLAN_PRICE, YEAR);
    }

    function _subscribe(uint128 maxAmount, uint64 period) internal {
        safe.execute(
            address(module), abi.encodeCall(SolidSubscriptionModule.subscribe, (maxAmount, period))
        );
    }

    function _charge(bytes32 billingId, uint256 amount) internal {
        vm.prank(biller);
        module.charge(address(safe), billingId, amount);
    }

    //============================== THE MANDATE ===============================

    function testSubscribeRecordsTheMandate() external view {
        SolidSubscriptionModule.Subscription memory subscription = module.subscriptionOf(address(safe));

        assertTrue(subscription.registered, "the Safe is subscribed");
        assertEq(subscription.maxAmountPerPeriod, PLAN_PRICE, "at the plan price");
        assertEq(subscription.periodSeconds, YEAR, "billed annually");
        assertEq(subscription.lastChargedAt, 0, "and never yet billed");
        assertEq(module.nextChargeDueAt(address(safe)), 0, "so the first charge is due now");
    }

    function testMandateIsBoundedByTheOrgCeiling() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__ExceedsOrgCeiling.selector,
                ORG_CEILING + 1,
                ORG_CEILING
            )
        );
        _subscribe(ORG_CEILING + 1, YEAR);
    }

    function testMandatePeriodIsBounded() external {
        uint64 tooShort = module.MIN_PERIOD() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__PeriodOutOfRange.selector, tooShort
            )
        );
        _subscribe(PLAN_PRICE, tooShort);

        uint64 tooLong = module.MAX_PERIOD() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__PeriodOutOfRange.selector, tooLong
            )
        );
        _subscribe(PLAN_PRICE, tooLong);
    }

    function testSubscribeRejectsAZeroMandate() external {
        vm.expectRevert(SolidSubscriptionModule.SolidSubscriptionModule__ZeroAmount.selector);
        _subscribe(0, YEAR);
    }

    //============================== CHARGING ===============================

    function testChargeMovesExactlyTheAmountToTheTreasury() external {
        _charge(keccak256("2026"), PLAN_PRICE);

        assertEq(usdc.balanceOf(treasury), PLAN_PRICE, "the treasury was paid");
        assertEq(usdc.balanceOf(address(safe)), 10_000e6 - PLAN_PRICE, "and the Safe debited");
        assertTrue(module.chargeCleared(address(safe), keccak256("2026")), "the id is spent");
        assertEq(
            module.nextChargeDueAt(address(safe)), uint64(block.timestamp) + YEAR, "the clock restarted"
        );
    }

    /**
     * The failure this mechanism is most likely to meet: a charge that landed
     * but whose receipt we never saw. Retrying must not bill a second time.
     */
    function testTheSameBillingIdCannotBeChargedTwice() external {
        bytes32 billingId = keccak256("2026");
        _charge(billingId, PLAN_PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__AlreadyCharged.selector,
                address(safe),
                billingId
            )
        );
        _charge(billingId, PLAN_PRICE);

        assertEq(usdc.balanceOf(treasury), PLAN_PRICE, "still billed once");
    }

    /// A fresh id is not a licence to bill early — the period gap is separate.
    function testANewBillingIdStillWaitsOutThePeriod() external {
        _charge(keccak256("2026"), PLAN_PRICE);

        uint64 dueAt = uint64(block.timestamp) + YEAR;
        vm.expectRevert(
            abi.encodeWithSelector(SolidSubscriptionModule.SolidSubscriptionModule__TooSoon.selector, dueAt)
        );
        _charge(keccak256("2026-again"), PLAN_PRICE);

        skip(YEAR);
        _charge(keccak256("2027"), PLAN_PRICE);

        assertEq(usdc.balanceOf(treasury), 2 * uint256(PLAN_PRICE), "a year later, the renewal");
    }

    function testChargeIsCappedByTheUsersOwnMandate() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__ExceedsMandate.selector,
                PLAN_PRICE + 1,
                PLAN_PRICE
            )
        );
        _charge(keccak256("2026"), PLAN_PRICE + 1);
    }

    /// Lowering the ceiling is a live throttle: it binds mandates already signed.
    function testLoweringTheOrgCeilingBindsExistingMandates() external {
        module.setMaxChargeAmount(100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__ExceedsOrgCeiling.selector, PLAN_PRICE, 100e6
            )
        );
        _charge(keccak256("2026"), PLAN_PRICE);
    }

    function testChargeRejectsZero() external {
        vm.expectRevert(SolidSubscriptionModule.SolidSubscriptionModule__ZeroAmount.selector);
        _charge(keccak256("2026"), 0);
    }

    function testUnsubscribedSafeCannotBeCharged() external {
        MockSafe other = new MockSafe();
        other.enableModule(address(module));
        usdc.mint(address(other), 1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__NotRegistered.selector, address(other)
            )
        );
        vm.prank(biller);
        module.charge(address(other), keccak256("2026"), PLAN_PRICE);
    }

    //============================== REVOKING CONSENT ===============================

    function testCancelStopsTheChargeAndResumeRestoresIt() external {
        safe.execute(address(module), abi.encodeCall(SolidSubscriptionModule.cancel, ()));

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__Cancelled.selector, address(safe)
            )
        );
        _charge(keccak256("2026"), PLAN_PRICE);

        safe.execute(address(module), abi.encodeCall(SolidSubscriptionModule.resume, ()));
        _charge(keccak256("2026"), PLAN_PRICE);

        assertEq(usdc.balanceOf(treasury), PLAN_PRICE, "resuming restores billing");
    }

    /**
     * Disabling the module is the stronger revocation, available from any Safe
     * client with no call to us, and it takes effect on the next block.
     */
    function testDisablingTheModuleStopsBillingImmediately() external {
        safe.disableModule(address(module));

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__ModuleNotEnabled.selector, address(safe)
            )
        );
        _charge(keccak256("2026"), PLAN_PRICE);
    }

    /**
     * Re-subscribing must not be a way to escape the period gap: `lastChargedAt`
     * survives, so a user cannot be billed twice in one year by cancelling and
     * signing up again.
     */
    function testResubscribingDoesNotResetTheBillingClock() external {
        _charge(keccak256("2026"), PLAN_PRICE);

        safe.execute(address(module), abi.encodeCall(SolidSubscriptionModule.cancel, ()));
        _subscribe(PLAN_PRICE, YEAR);

        uint64 dueAt = module.nextChargeDueAt(address(safe));
        assertEq(dueAt, uint64(block.timestamp) + YEAR, "the clock kept running");

        vm.expectRevert(
            abi.encodeWithSelector(SolidSubscriptionModule.SolidSubscriptionModule__TooSoon.selector, dueAt)
        );
        _charge(keccak256("2026-b"), PLAN_PRICE);
    }

    function testCancelRefusesToRepeat() external {
        safe.execute(address(module), abi.encodeCall(SolidSubscriptionModule.cancel, ()));

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__AlreadyCancelled.selector, address(safe)
            )
        );
        safe.execute(address(module), abi.encodeCall(SolidSubscriptionModule.cancel, ()));
    }

    function testCancelRequiresASubscription() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__NotRegistered.selector, stranger
            )
        );
        vm.prank(stranger);
        module.cancel();
    }

    function testResumeRequiresACancellation() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__NotCancelled.selector, address(safe)
            )
        );
        safe.execute(address(module), abi.encodeCall(SolidSubscriptionModule.resume, ()));
    }

    //============================== PAUSING ===============================

    function testGlobalAndPerSafePauses() external {
        module.pause();
        vm.expectRevert(SolidSubscriptionModule.SolidSubscriptionModule__Paused.selector);
        _charge(keccak256("2026"), PLAN_PRICE);
        module.unpause();

        module.setSafePaused(address(safe), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__SafePaused.selector, address(safe)
            )
        );
        _charge(keccak256("2026"), PLAN_PRICE);

        module.setSafePaused(address(safe), false);
        _charge(keccak256("2026"), PLAN_PRICE);
        assertEq(usdc.balanceOf(treasury), PLAN_PRICE, "unpausing restores billing");
    }

    //============================== ACCESS ===============================

    function testOnlyTheBillerMayCharge() external {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(stranger);
        module.charge(address(safe), keccak256("2026"), PLAN_PRICE);
    }

    function testAdminFunctionsAreGated() external {
        vm.startPrank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        module.pause();

        vm.expectRevert("UNAUTHORIZED");
        module.setMaxChargeAmount(1);

        vm.expectRevert("UNAUTHORIZED");
        module.setSafePaused(address(safe), true);
        vm.stopPrank();
    }

    /**
     * The mandate can only be written by the account whose money it commits.
     * A stranger calling `subscribe` writes a mandate against *their own*
     * address, which is nobody's Safe and therefore worth nothing.
     */
    function testAStrangerCannotSubscribeSomeoneElse() external {
        vm.prank(stranger);
        module.subscribe(PLAN_PRICE, YEAR);

        assertTrue(module.subscriptionOf(stranger).registered, "they subscribed themselves");

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidSubscriptionModule.SolidSubscriptionModule__ModuleNotEnabled.selector, stranger
            )
        );
        vm.prank(biller);
        module.charge(stranger, keccak256("2026"), PLAN_PRICE);
    }

    //============================== THE LENS ===============================

    function testCanChargeExplainsEveryRefusal() external {
        (bool ok, string memory reason) = module.canCharge(address(safe), PLAN_PRICE);
        assertTrue(ok, "a fresh mandate can be charged");
        assertEq(reason, "", "with nothing to explain");

        (ok, reason) = module.canCharge(address(safe), PLAN_PRICE + 1);
        assertFalse(ok);
        assertEq(reason, "exceeds mandate");

        (ok, reason) = module.canCharge(stranger, PLAN_PRICE);
        assertFalse(ok);
        assertEq(reason, "not subscribed");

        _charge(keccak256("2026"), PLAN_PRICE);
        (ok, reason) = module.canCharge(address(safe), PLAN_PRICE);
        assertFalse(ok);
        assertEq(reason, "too soon");

        skip(YEAR);
        safe.disableModule(address(module));
        (ok, reason) = module.canCharge(address(safe), PLAN_PRICE);
        assertFalse(ok);
        assertEq(reason, "module not enabled");

        safe.enableModule(address(module));
        module.setSafePaused(address(safe), true);
        (ok, reason) = module.canCharge(address(safe), PLAN_PRICE);
        assertFalse(ok);
        assertEq(reason, "safe paused");

        module.setSafePaused(address(safe), false);
        module.pause();
        (ok, reason) = module.canCharge(address(safe), PLAN_PRICE);
        assertFalse(ok);
        assertEq(reason, "module paused");
    }

    function testCanChargeSeesAnEmptySafe() external {
        MockSafe broke = new MockSafe();
        broke.enableModule(address(module));
        vm.prank(address(broke));
        module.subscribe(PLAN_PRICE, YEAR);

        (bool ok, string memory reason) = module.canCharge(address(broke), PLAN_PRICE);
        assertFalse(ok);
        assertEq(reason, "insufficient balance");
    }

    /**
     * A Safe too short for the fee reverts in the token, not in the module.
     * The debit must not be recorded as taken when nothing moved.
     */
    function testAChargeAgainstAnEmptySafeLeavesNoTrace() external {
        MockSafe broke = new MockSafe();
        broke.enableModule(address(module));
        vm.prank(address(broke));
        module.subscribe(PLAN_PRICE, YEAR);

        vm.expectRevert();
        vm.prank(biller);
        module.charge(address(broke), keccak256("2026"), PLAN_PRICE);

        assertFalse(module.chargeCleared(address(broke), keccak256("2026")), "the id is still free");
        assertEq(module.subscriptionOf(address(broke)).lastChargedAt, 0, "and the clock never started");
    }

    function testIsModuleEnabledOnAPlainAddress() external view {
        assertFalse(module.isModuleEnabledOn(stranger), "an EOA has no modules");
    }

    //============================== IMMUTABILITY ===============================

    /**
     * The property the whole design rests on: whoever holds the biller key can
     * choose the Safe and the amount, and nothing else. There is no setter for
     * the destination or the asset, so a compromised key can only ever move a
     * user's USDC to the treasury it was always going to move it to.
     */
    function testDestinationAndAssetHaveNoSetter() external view {
        assertEq(module.revenueTreasury(), treasury, "the destination is fixed");
        assertEq(address(module.billingToken()), address(usdc), "and so is the asset");
    }

    function testFuzzChargeNeverExceedsTheMandate(uint128 amount) external {
        amount = uint128(bound(amount, 1, ORG_CEILING));
        uint256 safeBefore = usdc.balanceOf(address(safe));

        if (amount > PLAN_PRICE) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    SolidSubscriptionModule.SolidSubscriptionModule__ExceedsMandate.selector, amount, PLAN_PRICE
                )
            );
            _charge(keccak256("2026"), amount);
            assertEq(usdc.balanceOf(address(safe)), safeBefore, "nothing moved");
            return;
        }

        _charge(keccak256("2026"), amount);
        assertEq(usdc.balanceOf(treasury), amount, "exactly the requested amount");
        assertEq(usdc.balanceOf(address(safe)), safeBefore - amount, "and only from the Safe");
    }
}
