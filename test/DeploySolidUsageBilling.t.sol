// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {DeploySolidUsageBilling} from "script/DeploySolidUsageBilling.s.sol";

/// @dev Answers `getThreshold()` like a Safe with that many signatures required.
contract ThresholdSafe {
    uint256 public getThreshold;

    constructor(uint256 threshold) {
        getThreshold = threshold;
    }
}

/// @dev Has code, but is no Safe: it could never make the owner's calls.
contract NotASafe {
    function hello() external pure returns (uint256) {
        return 1;
    }
}

contract DeploySolidUsageBillingTest is Test {
    DeploySolidUsageBilling internal script;

    function setUp() external {
        script = new DeploySolidUsageBilling();
    }

    function testAcceptsASafeNeedingTwoOrMoreSignatures() external {
        script.checkOwner(address(new ThresholdSafe(3)), false);
        script.checkOwner(address(new ThresholdSafe(2)), false);
    }

    function testRefusesASingleKeyOwner() external {
        address eoa = makeAddr("owner");
        address oneOfOne = address(new ThresholdSafe(1));
        address notASafe = address(new NotASafe());

        vm.expectRevert(
            "AI_BILLING_OWNER must be a Safe needing 2+ signatures (AI_BILLING_ALLOW_EOA_OWNER=true for QA only)"
        );
        script.checkOwner(eoa, false);
        vm.expectRevert(
            "AI_BILLING_OWNER must be a Safe needing 2+ signatures (AI_BILLING_ALLOW_EOA_OWNER=true for QA only)"
        );
        script.checkOwner(oneOfOne, false);
        vm.expectRevert(
            "AI_BILLING_OWNER must be a Safe needing 2+ signatures (AI_BILLING_ALLOW_EOA_OWNER=true for QA only)"
        );
        script.checkOwner(notASafe, false);
    }

    function testQaMayNameASingleKeyOwner() external {
        script.checkOwner(makeAddr("owner"), true);
    }

    function testNarrowsValuesThatFit() external view {
        (uint128 maxChargeAmount, uint64 minPeriod) = script.narrow(1_000e6, 1 days);
        assertEq(maxChargeAmount, 1_000e6);
        assertEq(minPeriod, 1 days);
    }

    function testRefusesValuesThatWouldTruncate() external {
        vm.expectRevert("AI_BILLING_MAX_CHARGE_AMOUNT must be above 0 and fit in uint128");
        script.narrow(uint256(type(uint128).max) + 2, 1 days);
        vm.expectRevert("AI_BILLING_MAX_CHARGE_AMOUNT must be above 0 and fit in uint128");
        script.narrow(0, 1 days);
        vm.expectRevert("AI_BILLING_MIN_PERIOD must fit in uint64");
        script.narrow(1_000e6, uint256(type(uint64).max) + 1 days);
    }
}
