// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test, Vm} from "@forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SolidCashStorageV2} from "src/spend-module/v2/SolidCashStorageV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {Mode, TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";
import {SolidCreditMathLib} from "src/spend-module/v2/libraries/SolidCreditMathLib.sol";

import {MockToken} from "../mocks/MockToken.sol";
import {V2Fixture} from "./V2Fixture.sol";

/**
 * @notice The per-token fee on `repayFromCollateral`: unset is at par, a set fee is debited on top of
 *         the collateral the credit is worth, and the fee always stays below the liquidation bonus.
 */
contract CollateralRepayFeeTest is V2Fixture {
    event RepaidFromCollateral(address indexed safe, address indexed token, uint256 tokenAmount, uint256 amountUsd);
    event CollateralRepayFeeCharged(address indexed safe, address indexed token, uint256 feeTokenAmount);
    event CollateralRepayFeeSet(address indexed token, uint16 feeBps);

    SolidCashModuleV2Setters internal viaCore;

    function setUp() public override {
        super.setUp();
        viaCore = SolidCashModuleV2Setters(address(module));

        _setMode(Mode.Credit);
        vm.prank(creditSpender);
        module.spendCredit(address(safe), bytes32("open"), 10_000e6, _pref(address(soUSD)));
    }

    // ===================================== DEFAULT =====================================

    function test_unsetFee_isZero_andRepaysAtPar() external {
        assertEq(viaCore.collateralRepayFeeBps(address(soUSD)), 0, "default fee not zero");

        (uint256 collateralBefore, uint256 debtBefore, uint256 treasuryBefore) = _snapshot();

        vm.recordLogs();
        vm.prank(address(safe));
        viaCore.repayFromCollateral(address(safe), address(soUSD), 1_000e6);

        assertEq(collateralBefore - module.collateralOf(address(safe), address(soUSD)), 1_000e6, "not at par");
        assertEq(debtBefore - module.debtUsd(address(safe)), 1_000e6, "debt retired");
        assertEq(soUSD.balanceOf(treasury) - treasuryBefore, 1_000e6, "treasury received");
        _assertNoFeeEvent();
    }

    // ===================================== CHARGING =====================================

    function test_fee_debitedOnTop_debtRetiredUnchanged() external {
        _setFee(address(soUSD), 100); // 1%, under the 5% bonus

        (uint256 collateralBefore, uint256 debtBefore, uint256 treasuryBefore) = _snapshot();

        vm.expectEmit(true, true, false, true, address(module));
        emit RepaidFromCollateral(address(safe), address(soUSD), 1_010e6, 1_000e6);
        vm.expectEmit(true, true, false, true, address(module));
        emit CollateralRepayFeeCharged(address(safe), address(soUSD), 10e6);

        vm.prank(address(safe));
        viaCore.repayFromCollateral(address(safe), address(soUSD), 1_000e6);

        assertEq(collateralBefore - module.collateralOf(address(safe), address(soUSD)), 1_010e6, "principal + fee");
        assertEq(debtBefore - module.debtUsd(address(safe)), 1_000e6, "fee must not change debt retired");
        assertEq(soUSD.balanceOf(treasury) - treasuryBefore, 1_010e6, "fee goes to the treasury");
    }

    /// @dev The whole position, in one call, with a fee: principal plus fee still fits the escrow.
    function test_fee_fullRepay_clearsDebt() external {
        _setFee(address(soUSD), 100);
        uint256 debt = module.debtUsd(address(safe));
        uint256 collateralBefore = module.collateralOf(address(safe), address(soUSD));

        vm.prank(address(safe));
        viaCore.repayFromCollateral(address(safe), address(soUSD), type(uint256).max);

        assertEq(module.debtUsd(address(safe)), 0, "debt not cleared");
        uint256 principal = debt; // soUSD at $1, 6 decimals
        assertEq(
            collateralBefore - module.collateralOf(address(safe), address(soUSD)),
            principal + Math.mulDiv(principal, 100, 10_000, Math.Rounding.Ceil),
            "full repay debit"
        );
    }

    /// @dev Lowering the bonus is risk-reducing and immediate; the fee must follow it down.
    function test_fee_cappedAtCurrentBonus_afterBonusLowered() external {
        _setFee(address(soUSD), 400);

        TokenConfig memory cfg = _sousdConfig();
        cfg.liquidationBonusBps = 200;
        vm.prank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.updateToken, (address(soUSD), cfg)));
        assertEq(viaCore.getTokenConfig(address(soUSD)).liquidationBonusBps, 200, "setup: bonus change delayed");

        uint256 collateralBefore = module.collateralOf(address(safe), address(soUSD));
        vm.prank(address(safe));
        viaCore.repayFromCollateral(address(safe), address(soUSD), 1_000e6);

        assertEq(collateralBefore - module.collateralOf(address(safe), address(soUSD)), 1_020e6, "fee above bonus");
    }

    function test_fee_zeroAgain_restoresPar() external {
        _setFee(address(soUSD), 100);
        _setFee(address(soUSD), 0);

        uint256 collateralBefore = module.collateralOf(address(safe), address(soUSD));
        vm.prank(address(safe));
        viaCore.repayFromCollateral(address(safe), address(soUSD), 1_000e6);

        assertEq(collateralBefore - module.collateralOf(address(safe), address(soUSD)), 1_000e6, "not at par");
    }

    // ===================================== SETTER =====================================

    function test_setFee_emitsAndStores() external {
        vm.expectEmit(true, false, false, true, address(module));
        emit CollateralRepayFeeSet(address(soUSD), 250);
        _setFee(address(soUSD), 250);

        assertEq(viaCore.collateralRepayFeeBps(address(soUSD)), 250);
    }

    /// @dev The `requiresAuth` refactor must keep solmate's revert data exactly.
    function test_setFee_requiresAuth() external {
        vm.prank(outsider);
        vm.expectRevert("UNAUTHORIZED");
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (address(soUSD), 100)));
    }

    function test_setFee_requiresAllowlistedToken() external {
        address stranger = makeAddr("strangerToken");
        vm.prank(owner);
        vm.expectRevert(SolidCashStorageV2.TokenNotAllowed.selector);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (stranger, 100)));
    }

    function test_setFee_mustBeBelowBonus() external {
        vm.startPrank(owner);
        vm.expectRevert(SolidCashStorageV2.InvalidInput.selector);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (address(soUSD), 500)));

        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (address(soUSD), 499)));
        vm.stopPrank();
        assertEq(viaCore.collateralRepayFeeBps(address(soUSD)), 499);
    }

    /// @dev USDT has no bonus, so it can carry no fee — but zero is always settable.
    function test_setFee_noBonusMeansNoFee() external {
        vm.startPrank(owner);
        vm.expectRevert(SolidCashStorageV2.InvalidInput.selector);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (address(usdt), 1)));

        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (address(usdt), 0)));
        vm.stopPrank();
    }

    function test_disallowToken_clearsFee() external {
        MockToken soETH = new MockToken("Solid ETH", "soETH", 18);
        provider.setPrice(address(soETH), 3_000e6);
        TokenConfig memory cfg = _sousdConfig();
        cfg.tokenDecimals = 18;
        cfg.minPriceUsd = 1_000e6;
        cfg.maxPriceUsd = 10_000e6;

        vm.startPrank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.allowToken, (address(soETH), cfg)));
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (address(soETH), 100)));
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.disallowToken, (address(soETH))));
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.allowToken, (address(soETH), cfg)));
        vm.stopPrank();

        assertEq(viaCore.collateralRepayFeeBps(address(soETH)), 0, "stale fee survived disallowToken");
    }

    // ===================================== HELPERS =====================================

    function _setFee(address token, uint16 feeBps) internal {
        vm.prank(owner);
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setCollateralRepayFee, (token, feeBps)));
    }

    function _snapshot() internal view returns (uint256 collateral, uint256 debt, uint256 treasuryBalance) {
        collateral = module.collateralOf(address(safe), address(soUSD));
        debt = module.debtUsd(address(safe));
        treasuryBalance = soUSD.balanceOf(treasury);
    }

    function _assertNoFeeEvent() internal {
        bytes32 topic = CollateralRepayFeeCharged.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0) assertTrue(logs[i].topics[0] != topic, "fee event at zero fee");
        }
    }
}

/// @notice The sizing arithmetic on its own, where every rounding direction can be fuzzed.
contract SizeCollateralRepayTest is Test {
    uint256 internal constant MAX_BPS = 10_000;

    /// @dev At a zero fee every figure matches the at-par sizing this replaced.
    function testFuzz_zeroFee_matchesAtPar(uint256 amountUsd, uint256 price, uint8 decimals, uint256 available)
        external
        pure
    {
        (amountUsd, price, available, decimals) = _boundInputs(amountUsd, price, available, decimals);
        uint256 unit = 10 ** decimals;

        uint256 expectedTokens = Math.mulDiv(amountUsd, unit, price, Math.Rounding.Ceil);
        uint256 expectedCredit = amountUsd;
        if (expectedTokens > available) {
            expectedTokens = available;
            expectedCredit = Math.mulDiv(available, price, unit, Math.Rounding.Floor);
        }
        vm.assume(expectedTokens != 0 && expectedCredit != 0);

        (uint256 tokenAmount, uint256 feeAmount, uint256 creditedUsd) =
            SolidCreditMathLib.sizeCollateralRepay(amountUsd, price, unit, available, 0);

        assertEq(tokenAmount, expectedTokens, "tokens");
        assertEq(feeAmount, 0, "fee");
        assertEq(creditedUsd, expectedCredit, "credit");
    }

    function testFuzz_withFee_neverOverdrawsOrOvercredits(
        uint256 amountUsd,
        uint256 price,
        uint8 decimals,
        uint256 available,
        uint16 feeBps
    ) external {
        (amountUsd, price, available, decimals) = _boundInputs(amountUsd, price, available, decimals);
        feeBps = uint16(bound(feeBps, 0, 5_000));
        uint256 unit = 10 ** decimals;

        (bool ok, bytes memory ret) = address(this).call(
            abi.encodeCall(this.size, (amountUsd, price, unit, available, feeBps))
        );
        vm.assume(ok);
        (uint256 tokenAmount, uint256 feeAmount, uint256 creditedUsd) = abi.decode(ret, (uint256, uint256, uint256));

        assertLe(tokenAmount, available, "debited more than escrowed");
        assertLe(creditedUsd, amountUsd, "credited more than requested");
        assertLe(feeAmount, tokenAmount, "fee exceeds debit");

        // The principal left after the fee always covers the credit, at the module's own price.
        assertGe(Math.mulDiv(tokenAmount - feeAmount, price, unit, Math.Rounding.Floor), creditedUsd, "principal");

        uint256 principal = Math.mulDiv(amountUsd, unit, price, Math.Rounding.Ceil);
        uint256 fullFee = Math.mulDiv(principal, feeBps, MAX_BPS, Math.Rounding.Ceil);
        if (principal + fullFee <= available) {
            assertEq(creditedUsd, amountUsd, "uncapped credit");
            assertEq(feeAmount, fullFee, "uncapped fee");
            assertEq(tokenAmount, principal + fullFee, "uncapped debit");
        } else {
            assertEq(tokenAmount, available, "capped debit");
        }
    }

    function size(uint256 amountUsd, uint256 price, uint256 unit, uint256 available, uint256 feeBps)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return SolidCreditMathLib.sizeCollateralRepay(amountUsd, price, unit, available, feeBps);
    }

    function _boundInputs(uint256 amountUsd, uint256 price, uint256 available, uint8 decimals)
        internal
        pure
        returns (uint256, uint256, uint256, uint8)
    {
        return (
            bound(amountUsd, 1, 1e15), // up to $1bn
            bound(price, 1, 1e12), // up to $1m per token
            bound(available, 0, 1e30),
            uint8(bound(decimals, 6, 18))
        );
    }
}
