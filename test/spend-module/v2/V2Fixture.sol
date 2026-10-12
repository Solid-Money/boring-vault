// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {Authority} from "@solmate/auth/Auth.sol";
import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";

import {SolidCashModuleV2} from "src/spend-module/v2/SolidCashModuleV2.sol";
import {SolidCashModuleV2Setters} from "src/spend-module/v2/SolidCashModuleV2Setters.sol";
import {SolidLiquidator} from "src/spend-module/v2/SolidLiquidator.sol";
import {Mode, Params, TokenConfig} from "src/spend-module/v2/SolidCashTypes.sol";

import {MockSafe} from "../mocks/MockSafe.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockPriceProviderV2} from "./mocks/MockPriceProviderV2.sol";

/**
 * @notice Shared deployment for the v2 security-remediation suites.
 *
 * @dev Deliberately mirrors the real role table rather than granting everything to one key, because
 *      most of what these suites assert is about which key can reach what. In particular
 *      `liquidationOperator` is its own address and holds no spender role — the two-key split is
 *      the property under test, so a fixture that collapsed it would make the suite pass vacuously.
 *
 *      Two tokens: soUSD (collateral, tender) and USDT (spendable, NOT tender), which is the launch
 *      shape and the one that makes the tender assertions mean something.
 */
abstract contract V2Fixture is Test {
    uint8 internal constant SPENDER_ROLE = 1;
    uint8 internal constant CREDIT_SPENDER_ROLE = 2;
    uint8 internal constant GUARDIAN_ROLE = 3;
    uint8 internal constant LIQUIDATOR_ROLE = 4;
    uint8 internal constant LIQUIDATION_OPERATOR_ROLE = 5;

    uint256 internal constant WAD = 1e18;

    address internal owner = makeAddr("owner");
    address internal spender = makeAddr("spender");
    address internal creditSpender = makeAddr("creditSpender");
    address internal guardian = makeAddr("guardian");
    address internal liquidationOperator = makeAddr("liquidationOperator");
    address internal outsider = makeAddr("outsider");
    address internal treasury = makeAddr("treasury");
    address internal v1Module = makeAddr("v1Module");

    FuseRolesAuthority internal authority;
    MockPriceProviderV2 internal provider;
    SolidCashModuleV2 internal module;
    SolidCashModuleV2Setters internal setters;
    SolidLiquidator internal liquidator;
    MockSafe internal safe;
    MockToken internal soUSD;
    MockToken internal usdt;

    uint64 internal constant GRACE = 1 days;
    uint256 internal constant MAX_PER_TX = 25_000e6;
    uint256 internal constant DAILY = 25_000e6;
    uint256 internal constant MONTHLY = 250_000e6;
    uint256 internal constant MAX_FORCED = 25_000e6;

    function setUp() public virtual {
        vm.warp(1_750_000_000);

        soUSD = new MockToken("Solid USD", "soUSD", 6);
        usdt = new MockToken("Tether", "USDT", 6);

        provider = new MockPriceProviderV2();
        provider.setPrice(address(soUSD), 1e6);
        provider.setPrice(address(usdt), 1e6);

        authority = new FuseRolesAuthority(owner, Authority(address(0)));

        setters = new SolidCashModuleV2Setters(owner, address(authority), treasury, v1Module);
        module = new SolidCashModuleV2(owner, address(authority), treasury, v1Module, address(provider));
        liquidator = new SolidLiquidator(owner, address(authority), address(module), treasury);

        vm.startPrank(owner);
        module.setSettersImpl(address(setters));
        _grantRoles();
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setParams, (_params())));
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.allowToken, (address(soUSD), _sousdConfig())));
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.allowToken, (address(usdt), _usdtConfig())));
        // Launch tender: soUSD only in this fixture, so USDT is the negative case throughout.
        _callSetters(abi.encodeCall(SolidCashModuleV2Setters.setRepayTender, (address(soUSD), true)));
        vm.stopPrank();

        safe = new MockSafe();
        safe.enableModule(address(module));
        soUSD.mint(address(safe), 100_000e6);
        usdt.mint(address(safe), 100_000e6);

        vm.prank(address(safe));
        module.registerSafe(0, 0, 0);

        // The float the liquidator repays out of. Treasury money; `sweep` returns it.
        soUSD.mint(address(liquidator), 1_000_000e6);
    }

    function _grantRoles() internal {
        address core = address(module);

        authority.setRoleCapability(SPENDER_ROLE, core, SolidCashModuleV2.spend.selector, true);

        authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.spendCredit.selector, true);
        authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.bookForcedSpend.selector, true);
        authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.adjustBookedSpend.selector, true);
        authority.setRoleCapability(CREDIT_SPENDER_ROLE, core, SolidCashModuleV2.reverseSpend.selector, true);

        authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.pause.selector, true);
        authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setTokenPaused.selector, true);
        authority.setRoleCapability(GUARDIAN_ROLE, core, SolidCashModuleV2Setters.setLiquidationsPaused.selector, true);

        // The role goes to the CONTRACT. An EOA here would reopen the extraction the split closes.
        authority.setRoleCapability(LIQUIDATOR_ROLE, core, SolidCashModuleV2.liquidate.selector, true);
        authority.setUserRole(address(liquidator), LIQUIDATOR_ROLE, true);

        authority.setRoleCapability(
            LIQUIDATION_OPERATOR_ROLE, address(liquidator), SolidLiquidator.liquidate.selector, true
        );
        authority.setUserRole(liquidationOperator, LIQUIDATION_OPERATOR_ROLE, true);

        authority.setUserRole(spender, SPENDER_ROLE, true);
        authority.setUserRole(creditSpender, CREDIT_SPENDER_ROLE, true);
        authority.setUserRole(guardian, GUARDIAN_ROLE, true);
    }

    /// @dev Configuration lives behind the core's fallback, so every setter call goes through it.
    function _callSetters(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(module).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _params() internal pure virtual returns (Params memory) {
        return Params({
            maxPerTxUsd: MAX_PER_TX,
            maxDailyLimitUsd: DAILY,
            maxMonthlyLimitUsd: MONTHLY,
            defaultDailyLimitUsd: DAILY,
            defaultMonthlyLimitUsd: MONTHLY,
            maxDebtPerSafeUsd: 25_000e6,
            maxGlobalDebtUsd: 250_000e6,
            maxForcedSpendUsd: MAX_FORCED,
            dustFloorUsd: 0,
            minPositionUsd: 25e6,
            targetLtvBps: 9_500,
            closeFactorBps: 5_000,
            maxAdjustmentBps: 2_500,
            modeDelay: 0,
            limitRaiseDelay: 0,
            collateralWithdrawDelay: 5 minutes,
            // The launch decision, and the value several assertions below depend on.
            liquidationGracePeriod: GRACE,
            graceFloorHf: 0.95e18,
            paramChangeDelay: GRACE,
            limitWaiveDelay: 1 hours
        });
    }

    function _sousdConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: true,
            tokenDecimals: 6,
            haircutBps: 0,
            liquidationBonusBps: 500,
            ltv: 0.90e18,
            liquidationThreshold: 0.95e18,
            maxStalenessSeconds: 7 days,
            minPriceUsd: 0.95e6,
            maxPriceUsd: 3e6,
            ceilingGrowthPerSec: 0,
            ceilingAnchor: 0
        });
    }

    /// @dev Spendable, never collateral, never tender. The launch shape for a third-party stable.
    function _usdtConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            spendable: true,
            collateral: false,
            tokenDecimals: 6,
            haircutBps: 0,
            liquidationBonusBps: 0,
            ltv: 0,
            liquidationThreshold: 0,
            maxStalenessSeconds: 1 days,
            minPriceUsd: 0.98e6,
            maxPriceUsd: 1.02e6,
            ceilingGrowthPerSec: 0,
            ceilingAnchor: 0
        });
    }

    function _pref(address token) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = token;
    }

    function _setMode(Mode mode) internal {
        vm.prank(address(safe));
        module.setMode(mode);
    }
}
