// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";

import {SolidUsageBillingModule} from "src/solid-billing/SolidUsageBillingModule.sol";
import {MockCounterfeitSafe} from "test/mocks/MockCounterfeitSafe.sol";
import {MockFeeOnTransferERC20} from "test/mocks/MockFeeOnTransferERC20.sol";
import {MockMintableERC20} from "test/mocks/MockMintableERC20.sol";
import {MockRateAccountant} from "test/mocks/MockRateAccountant.sol";
import {MockSafe} from "test/mocks/MockSafe.sol";

contract SolidUsageBillingModuleTest is Test {
    uint8 internal constant BILLER_ROLE = 4;

    /// @dev Every amount here is micro-USD: $1 is 1e6.
    uint128 internal constant DAILY_MANDATE = 100e6;
    uint128 internal constant ORG_CEILING = 10_000e6;
    uint64 internal constant MIN_PERIOD = 12 hours;
    uint64 internal constant DAY = 23 hours;

    /// @dev soUSD's accountant rate: one share is worth $1.07.
    uint256 internal constant SOUSD_RATE = 1.07e6;

    SolidUsageBillingModule internal module;
    RolesAuthority internal authority;
    MockMintableERC20 internal usdc;
    MockMintableERC20 internal soUsd;
    MockRateAccountant internal soUsdAccountant;
    MockSafe internal safe;

    address internal treasury = address(0x7EA5);
    address internal biller = address(0xB111E2);
    address internal stranger = address(0x57A);

    function setUp() external {
        usdc = new MockMintableERC20("USD Coin", "USDC", 6);
        soUsd = new MockMintableERC20("Solid USD", "soUSD", 6);
        soUsdAccountant = new MockRateAccountant(SOUSD_RATE);
        safe = new MockSafe();

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(soUsd);
        address[] memory providers = new address[](2);
        providers[1] = address(soUsdAccountant);

        module = new SolidUsageBillingModule(address(this), treasury, ORG_CEILING, MIN_PERIOD, tokens, providers);

        authority = new RolesAuthority(address(this), Authority(address(0)));
        authority.setRoleCapability(BILLER_ROLE, address(module), SolidUsageBillingModule.charge.selector, true);
        authority.setUserRole(biller, BILLER_ROLE, true);
        module.setAuthority(authority);

        safe.enableModule(address(module));
        _subscribe(safe, DAILY_MANDATE, DAY);
    }

    function _subscribe(MockSafe account, uint128 maxAmount, uint64 period) internal {
        account.execute(address(module), abi.encodeCall(SolidUsageBillingModule.subscribe, (maxAmount, period)));
    }

    function _charge(bytes32 billingId, uint256 amount) internal {
        vm.prank(biller);
        module.charge(address(safe), billingId, amount);
    }

    function _tokens(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    //============================== THE MANDATE ===============================

    function testSubscribeRecordsTheMandate() external view {
        SolidUsageBillingModule.Subscription memory subscription = module.subscriptionOf(address(safe));

        assertTrue(subscription.registered, "the Safe is subscribed");
        assertEq(subscription.maxAmountPerPeriod, DAILY_MANDATE, "up to the daily cap");
        assertEq(subscription.periodSeconds, DAY, "billed at most once a day");
        assertEq(module.nextChargeDueAt(address(safe)), 0, "so the first charge is due now");
    }

    /// The one thing the subscription module could not do: a daily mandate.
    function testADailyPeriodIsAccepted() external view {
        assertEq(module.minPeriod(), MIN_PERIOD, "the deployment chose its own floor");
        assertLt(uint256(DAY), 7 days, "below the subscription module's hard-coded week");
    }

    function testMandatePeriodIsBoundedByTheDeployment() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__PeriodOutOfRange.selector, MIN_PERIOD - 1
            )
        );
        _subscribe(safe, DAILY_MANDATE, MIN_PERIOD - 1);

        uint64 tooLong = module.MAX_PERIOD() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__PeriodOutOfRange.selector, tooLong)
        );
        _subscribe(safe, DAILY_MANDATE, tooLong);
    }

    function testMandateIsBoundedByTheOrgCeiling() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__ExceedsOrgCeiling.selector, ORG_CEILING + 1, ORG_CEILING
            )
        );
        _subscribe(safe, ORG_CEILING + 1, DAY);
    }

    function testSubscribeRejectsAZeroMandate() external {
        vm.expectRevert(SolidUsageBillingModule.SolidUsageBillingModule__ZeroAmount.selector);
        _subscribe(safe, 0, DAY);
    }

    //============================== DRAW ORDER ===============================

    function testChargeTakesUsdcFirst() external {
        usdc.mint(address(safe), 50e6);
        soUsd.mint(address(safe), 50e6);

        _charge(keccak256("day-1"), 30e6);

        assertEq(usdc.balanceOf(treasury), 30e6, "all of it from USDC");
        assertEq(soUsd.balanceOf(treasury), 0, "soUSD untouched while USDC covers it");
        assertEq(usdc.balanceOf(address(safe)), 20e6, "the Safe debited");
    }

    function testChargeMovesOnToSoUsdWhenUsdcRunsOut() external {
        usdc.mint(address(safe), 10e6);
        soUsd.mint(address(safe), 50e6);

        _charge(keccak256("day-1"), 31_400_000); // $31.40

        assertEq(usdc.balanceOf(treasury), 10e6, "every USDC first");
        // $21.40 of soUSD at $1.07 a share is exactly 20 shares.
        assertEq(soUsd.balanceOf(treasury), 20e6, "then the rest in soUSD at its rate");
        assertEq(usdc.balanceOf(address(safe)), 0);
        assertEq(soUsd.balanceOf(address(safe)), 30e6);
    }

    function testAWalletWithOnlySoUsdIsChargedInSoUsd() external {
        soUsd.mint(address(safe), 100e6);

        _charge(keccak256("day-1"), 10_700_000); // $10.70

        assertEq(soUsd.balanceOf(treasury), 10e6, "10 shares at $1.07");
        assertEq(usdc.balanceOf(treasury), 0);
    }

    /// Units round up, so what a token settles is never less than it is credited with.
    function testRoundingNeverUnderpaysTheTreasury() external {
        soUsd.mint(address(safe), 100e6);

        _charge(keccak256("day-1"), 1_000_001);

        uint256 paid = soUsd.balanceOf(treasury);
        assertGe((paid * SOUSD_RATE) / 1e6, 1_000_001, "the shares paid are worth at least the charge");
        assertLe(paid, (1_000_001 * 1e6) / SOUSD_RATE + 1, "and at most one unit more");
    }

    function testAChargeTheWalletCannotCoverMovesNothing() external {
        usdc.mint(address(safe), 10e6);
        soUsd.mint(address(safe), 5e6); // $5.35

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__InsufficientBalance.selector, 20e6, 15_350_000
            )
        );
        _charge(keccak256("day-1"), 20e6);

        assertEq(usdc.balanceOf(treasury), 0, "no partial charge");
        assertFalse(module.chargeCleared(address(safe), keccak256("day-1")), "the id is still free");
        assertEq(module.subscriptionOf(address(safe)).lastChargedAt, 0, "and the clock never started");
    }

    function testBillableBalanceAndQuoteDescribeTheDraw() external {
        usdc.mint(address(safe), 10e6);
        soUsd.mint(address(safe), 50e6);

        assertEq(module.billableBalanceOf(address(safe)), 10e6 + 53_500_000, "USDC plus soUSD at its rate");

        (SolidUsageBillingModule.Draw[] memory draws, uint256 drawn) = module.quote(address(safe), 31_400_000);
        assertEq(draws.length, 2, "two tokens drawn from");
        assertEq(draws[0].token, address(usdc));
        assertEq(draws[0].units, 10e6);
        assertEq(draws[1].token, address(soUsd));
        assertEq(draws[1].units, 20e6);
        assertEq(drawn, 31_400_000, "covering the whole charge");
    }

    //============================== THE TOKEN LIST ===============================

    /// A token added later is billable with no new signature from the user.
    function testAddingATokenNeedsNoNewSignature() external {
        MockMintableERC20 usdt = new MockMintableERC20("Tether", "USDT", 6);
        usdt.mint(address(safe), 40e6);

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(soUsd);
        tokens[2] = address(usdt);
        module.setBillingTokens(tokens, new address[](3));

        _charge(keccak256("day-1"), 25e6);

        assertEq(usdt.balanceOf(treasury), 25e6, "charged from the new token under the old mandate");
    }

    function testTheListIsReplacedWholeAndInOrder() external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(soUsd);
        tokens[1] = address(usdc);
        address[] memory providers = new address[](2);
        providers[0] = address(soUsdAccountant);
        module.setBillingTokens(tokens, providers);

        usdc.mint(address(safe), 50e6);
        soUsd.mint(address(safe), 50e6);
        _charge(keccak256("day-1"), 10_700_000);

        assertEq(soUsd.balanceOf(treasury), 10e6, "the new order draws soUSD first");
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function testRemovingATokenStopsItBeingDrawn() external {
        module.setBillingTokens(_tokens(address(usdc)), new address[](1));
        soUsd.mint(address(safe), 100e6);

        (bool ok, string memory reason) = module.canCharge(address(safe), 1e6);
        assertFalse(ok);
        assertEq(reason, "insufficient balance", "soUSD no longer counts");
    }

    function testSetBillingTokensRejectsABadList() external {
        address[] memory dup = new address[](2);
        dup[0] = address(usdc);
        dup[1] = address(usdc);
        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__DuplicateToken.selector, address(usdc))
        );
        module.setBillingTokens(dup, new address[](2));

        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__InvalidToken.selector, stranger)
        );
        module.setBillingTokens(_tokens(stranger), new address[](1));

        address[] memory badProvider = new address[](1);
        badProvider[0] = stranger;
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__InvalidRateProvider.selector, address(soUsd), stranger
            )
        );
        module.setBillingTokens(_tokens(address(soUsd)), badProvider);

        vm.expectRevert(SolidUsageBillingModule.SolidUsageBillingModule__LengthMismatch.selector);
        module.setBillingTokens(_tokens(address(usdc)), new address[](2));

        address[] memory nine = new address[](9);
        vm.expectRevert(abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__TooManyTokens.selector, 9));
        module.setBillingTokens(nine, new address[](9));
    }

    /// A provider that answers zero is refused when set — a price of nothing is no price.
    function testARateProviderMustAnswerWhenSet() external {
        MockRateAccountant dead = new MockRateAccountant(0);
        address[] memory providers = new address[](1);
        providers[0] = address(dead);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__InvalidRateProvider.selector, address(soUsd), address(dead)
            )
        );
        module.setBillingTokens(_tokens(address(soUsd)), providers);
    }

    /// A provider that stops answering later takes its token out of the draw, nothing more.
    function testATokenWhosePriceIsUnreadableIsSkipped() external {
        usdc.mint(address(safe), 50e6);
        soUsd.mint(address(safe), 50e6);
        soUsdAccountant.setShouldRevert(true);

        assertEq(module.billableBalanceOf(address(safe)), 50e6, "soUSD counts for nothing while unpriced");

        _charge(keccak256("day-1"), 40e6);
        assertEq(usdc.balanceOf(treasury), 40e6, "USDC still charges");

        skip(DAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__InsufficientBalance.selector, 20e6, 10e6
            )
        );
        _charge(keccak256("day-2"), 20e6);
    }

    //============================== IDEMPOTENCY AND TIMING ===============================

    function testTheSameBillingIdCannotBeChargedTwice() external {
        usdc.mint(address(safe), 100e6);
        bytes32 billingId = keccak256("day-1");
        _charge(billingId, 10e6);

        skip(DAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__AlreadyCharged.selector, address(safe), billingId
            )
        );
        _charge(billingId, 10e6);

        assertEq(usdc.balanceOf(treasury), 10e6, "still billed once");
    }

    function testANewBillingIdStillWaitsOutThePeriod() external {
        usdc.mint(address(safe), 100e6);
        _charge(keccak256("day-1"), 10e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__TooSoon.selector, uint64(block.timestamp) + DAY
            )
        );
        _charge(keccak256("day-2"), 10e6);

        skip(DAY);
        _charge(keccak256("day-2"), 10e6);
        assertEq(usdc.balanceOf(treasury), 20e6, "the next day's charge clears once the period is up");
    }

    function testResubscribingDoesNotResetTheClock() external {
        usdc.mint(address(safe), 100e6);
        _charge(keccak256("day-1"), 10e6);

        safe.execute(address(module), abi.encodeCall(SolidUsageBillingModule.cancel, ()));
        _subscribe(safe, DAILY_MANDATE * 2, DAY);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__TooSoon.selector, uint64(block.timestamp) + DAY
            )
        );
        _charge(keccak256("day-2"), 10e6);
    }

    //============================== LIMITS ===============================

    function testChargeIsCappedByTheUsersOwnMandate() external {
        usdc.mint(address(safe), 1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__ExceedsMandate.selector, DAILY_MANDATE + 1, DAILY_MANDATE
            )
        );
        _charge(keccak256("day-1"), DAILY_MANDATE + 1);
    }

    function testLoweringTheOrgCeilingBindsExistingMandates() external {
        usdc.mint(address(safe), 1_000e6);
        module.setMaxChargeAmount(50e6);

        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__ExceedsOrgCeiling.selector, 60e6, 50e6)
        );
        _charge(keccak256("day-1"), 60e6);
    }

    function testChargeRejectsZero() external {
        vm.expectRevert(SolidUsageBillingModule.SolidUsageBillingModule__ZeroAmount.selector);
        _charge(keccak256("day-1"), 0);
    }

    //============================== CONSENT ===============================

    function testCancelStopsTheChargeAndResumeRestoresIt() external {
        usdc.mint(address(safe), 100e6);
        safe.execute(address(module), abi.encodeCall(SolidUsageBillingModule.cancel, ()));

        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__Cancelled.selector, address(safe))
        );
        _charge(keccak256("day-1"), 10e6);

        safe.execute(address(module), abi.encodeCall(SolidUsageBillingModule.resume, ()));
        _charge(keccak256("day-1"), 10e6);
        assertEq(usdc.balanceOf(treasury), 10e6);
    }

    function testDisablingTheModuleStopsBillingImmediately() external {
        usdc.mint(address(safe), 100e6);
        safe.disableModule(address(module));

        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__ModuleNotEnabled.selector, address(safe))
        );
        _charge(keccak256("day-1"), 10e6);
    }

    function testUnsubscribedSafeCannotBeCharged() external {
        MockSafe other = new MockSafe();
        other.enableModule(address(module));
        usdc.mint(address(other), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__NotRegistered.selector, address(other))
        );
        vm.prank(biller);
        module.charge(address(other), keccak256("day-1"), 10e6);
    }

    function testGlobalAndPerSafePauses() external {
        usdc.mint(address(safe), 100e6);

        module.setSafePaused(address(safe), true);
        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__SafePaused.selector, address(safe))
        );
        _charge(keccak256("day-1"), 10e6);

        module.setSafePaused(address(safe), false);
        module.pause();
        vm.expectRevert(SolidUsageBillingModule.SolidUsageBillingModule__Paused.selector);
        _charge(keccak256("day-1"), 10e6);

        module.unpause();
        _charge(keccak256("day-1"), 10e6);
    }

    //============================== ACCESS ===============================

    function testOnlyTheBillerMayCharge() external {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(stranger);
        module.charge(address(safe), keccak256("day-1"), 10e6);
    }

    function testAdminFunctionsAreGated() external {
        vm.startPrank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        module.pause();

        vm.expectRevert("UNAUTHORIZED");
        module.setMaxChargeAmount(1);

        vm.expectRevert("UNAUTHORIZED");
        module.setSafePaused(address(safe), true);

        vm.expectRevert("UNAUTHORIZED");
        module.setBillingTokens(_tokens(address(usdc)), new address[](1));
        vm.stopPrank();
    }

    /// The biller can choose the Safe and the amount — and not the token list.
    function testTheBillerCannotChangeWhatIsDrawn() external {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(biller);
        module.setBillingTokens(_tokens(address(usdc)), new address[](1));
    }

    //============================== THE LENS ===============================

    function testCanChargeExplainsEveryRefusal() external {
        usdc.mint(address(safe), 100e6);

        (bool ok, string memory reason) = module.canCharge(address(safe), 10e6);
        assertTrue(ok);
        assertEq(reason, "");

        (ok, reason) = module.canCharge(address(safe), DAILY_MANDATE + 1);
        assertEq(reason, "exceeds mandate");

        (ok, reason) = module.canCharge(stranger, 10e6);
        assertEq(reason, "not subscribed");

        (ok, reason) = module.canCharge(address(safe), 0);
        assertEq(reason, "zero amount");

        _charge(keccak256("day-1"), 10e6);
        (ok, reason) = module.canCharge(address(safe), 10e6);
        assertEq(reason, "too soon");

        skip(DAY);
        module.setMaxChargeAmount(5e6);
        (ok, reason) = module.canCharge(address(safe), 10e6);
        assertEq(reason, "exceeds org ceiling");
        module.setMaxChargeAmount(ORG_CEILING);

        (ok, reason) = module.canCharge(address(safe), 95e6);
        assertEq(reason, "insufficient balance");

        safe.disableModule(address(module));
        (ok, reason) = module.canCharge(address(safe), 10e6);
        assertEq(reason, "module not enabled");
        safe.enableModule(address(module));

        safe.execute(address(module), abi.encodeCall(SolidUsageBillingModule.cancel, ()));
        (ok, reason) = module.canCharge(address(safe), 10e6);
        assertEq(reason, "cancelled");
        safe.execute(address(module), abi.encodeCall(SolidUsageBillingModule.resume, ()));

        module.setSafePaused(address(safe), true);
        (ok, reason) = module.canCharge(address(safe), 10e6);
        assertEq(reason, "safe paused");

        module.setSafePaused(address(safe), false);
        module.pause();
        (ok, reason) = module.canCharge(address(safe), 10e6);
        assertFalse(ok);
        assertEq(reason, "module paused");
    }

    //============================== SETTLEMENT ===============================

    /// A contract that answers like a Safe and moves nothing pays nothing, and gets no receipt.
    function testACounterfeitSafeCannotFakeSettlement() external {
        MockCounterfeitSafe counterfeit = new MockCounterfeitSafe();
        usdc.mint(address(counterfeit), 100e6);
        counterfeit.execute(address(module), abi.encodeCall(SolidUsageBillingModule.subscribe, (DAILY_MANDATE, DAY)));

        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__NotSettled.selector, address(usdc), 10e6, 0)
        );
        vm.prank(biller);
        module.charge(address(counterfeit), keccak256("day-1"), 10e6);

        assertFalse(module.chargeCleared(address(counterfeit), keccak256("day-1")), "no receipt");
    }

    function testATokenThatUnderDeliversIsNotAcceptedAsPayment() external {
        MockFeeOnTransferERC20 leaky = new MockFeeOnTransferERC20("Leaky", "LKY", 6, 100);
        module.setBillingTokens(_tokens(address(leaky)), new address[](1));
        leaky.mint(address(safe), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                SolidUsageBillingModule.SolidUsageBillingModule__NotSettled.selector, address(leaky), 10e6, 9_900_000
            )
        );
        _charge(keccak256("day-1"), 10e6);
    }

    //============================== CONSTRUCTION ===============================

    function testDestinationHasNoSetter() external view {
        assertEq(module.revenueTreasury(), treasury);
    }

    function testConstructorRejectsAnUnusableTreasuryOrPeriod() external {
        address[] memory none = new address[](0);

        vm.expectRevert(SolidUsageBillingModule.SolidUsageBillingModule__InvalidAddress.selector);
        new SolidUsageBillingModule(address(this), address(0), ORG_CEILING, MIN_PERIOD, none, none);

        vm.expectRevert(SolidUsageBillingModule.SolidUsageBillingModule__InvalidAddress.selector);
        new SolidUsageBillingModule(address(0), treasury, ORG_CEILING, MIN_PERIOD, none, none);

        vm.expectRevert(
            abi.encodeWithSelector(SolidUsageBillingModule.SolidUsageBillingModule__InvalidMinPeriod.selector, 59 minutes)
        );
        new SolidUsageBillingModule(address(this), treasury, ORG_CEILING, 59 minutes, none, none);
    }

    //============================== PROPERTIES ===============================

    /// Whatever is drawn, the treasury receives at least the dollars charged, and never above the mandate.
    function testFuzzChargeSettlesTheAmountWithinTheMandate(uint64 usdcUnits, uint64 soUsdUnits, uint128 amount)
        external
    {
        amount = uint128(bound(amount, 1, DAILY_MANDATE));
        usdc.mint(address(safe), usdcUnits);
        soUsd.mint(address(safe), soUsdUnits);

        uint256 available = module.billableBalanceOf(address(safe));
        if (available < amount) {
            vm.expectRevert();
            _charge(keccak256("day-1"), amount);
            return;
        }

        _charge(keccak256("day-1"), amount);

        uint256 settled = usdc.balanceOf(treasury) + (soUsd.balanceOf(treasury) * SOUSD_RATE) / 1e6;
        assertGe(settled, amount, "the treasury got at least the charge");
        // At most one soUSD unit of rounding above it.
        assertLe(settled, uint256(amount) + 2, "and essentially no more");
    }

    /// The lens and the charge state the same conditions; they must never disagree.
    function testFuzzCanChargeAgreesWithCharge(uint128 amount, uint64 warpBy, bool cancelled, bool enabled, uint64 funds)
        external
    {
        amount = uint128(bound(amount, 0, DAILY_MANDATE * 2));
        usdc.mint(address(safe), funds);
        if (cancelled) safe.execute(address(module), abi.encodeCall(SolidUsageBillingModule.cancel, ()));
        if (!enabled) safe.disableModule(address(module));
        skip(bound(warpBy, 0, 2 days));

        (bool ok,) = module.canCharge(address(safe), amount);

        vm.prank(biller);
        (bool success,) =
            address(module).call(abi.encodeCall(SolidUsageBillingModule.charge, (address(safe), keccak256("x"), amount)));

        assertEq(success, ok, "canCharge predicts charge");
    }
}
