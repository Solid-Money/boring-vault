// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

/**
 * @notice Just the `getRate()` an accountant exposes, plus a switch to make it
 *         revert — which is the state `SolidTierLock.lockedAssetsOf` has to
 *         survive rather than propagate.
 */
contract MockRateAccountant {
    uint256 public rate;
    bool public shouldRevert;

    error MockRateAccountant__Paused();

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getRate() external view returns (uint256) {
        if (shouldRevert) revert MockRateAccountant__Paused();
        return rate;
    }
}
