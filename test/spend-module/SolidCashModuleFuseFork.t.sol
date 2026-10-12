// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test} from "@forge-std/Test.sol";

import {Authority} from "@solmate/auth/Auth.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {SolidCashLens} from "src/spend-module/SolidCashLens.sol";
import {SolidCashModule} from "src/spend-module/SolidCashModule.sol";
import {SolidPriceProvider} from "src/spend-module/SolidPriceProvider.sol";
import {IAccountant} from "src/spend-module/interfaces/IAccountant.sol";
import {PriceFeedConfig, PriceFeedKind} from "src/spend-module/interfaces/ISolidPriceProvider.sol";

import {MockSafe} from "./mocks/MockSafe.sol";

/**
 * @notice Fork test against the live soUSD and soETH deployments on Fuse (chain 122).
 * @dev The unit suites run against mocks, which proves the logic but not that the hand-written
 *      `IAccountant` tuple lines up with the deployed `AccountantWithRateProviders`, nor that the real
 *      accountants are denominated the way the price configuration claims. One field out of order there
 *      would misprice every spend while every unit test still passed, so both are verified here against
 *      the real contracts rather than assumed.
 *
 *      This is also where the soETH decimal hazard is pinned against live data: soUSD's accountant is
 *      denominated in USDC (6 decimals, ~$1) and soETH's in WETH (18 decimals, ~$3000). Asserting that
 *      distinction on-chain is what stops a future change from quietly reintroducing the assumption
 *      that an accountant's base asset is worth a dollar.
 *
 * Run with: forge test --match-contract SolidCashModuleFuseForkTest --fork-url https://rpc.fuse.io
 */
contract SolidCashModuleFuseForkTest is Test {
    /// @dev soUSD on Fuse - the LayerZero OFT share token users hold.
    address internal constant SOUSD = 0x75333830E7014e909535389a6E5b0C02aA62ca27;

    /// @dev Accountant pricing soUSD on Fuse, reached via the Fuse soUSD teller's `accountant()`.
    address internal constant SOUSD_ACCOUNTANT = 0x47A5e832E1178726dd13AdD762774A704878AD98;

    /// @dev USDC on Fuse - soUSD's accountant base asset.
    address internal constant USDC = 0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9;

    /// @dev soETH on Fuse and its accountant, whose base is WETH rather than a dollar-like asset.
    address internal constant SOETH = 0xEf1c1fFbEabDF358E61D3F5F14777e9c1bC8D1c7;
    address internal constant SOETH_ACCOUNTANT = 0x4BD5873720072b4AC7956898dbCBc543b2fD3749;
    address internal constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;

    uint8 internal constant SPENDER_ROLE = 1;

    address internal owner = makeAddr("owner");
    address internal spender = makeAddr("spender");
    address internal treasury = makeAddr("treasury");

    SolidPriceProvider internal provider;
    SolidCashModule internal module;
    SolidCashLens internal lens;
    MockSafe internal safe;

    modifier onFuse() {
        vm.skip(block.chainid != 122);
        _;
    }

    function setUp() external {
        // Skip cleanly when the suite is run without a Fuse fork rather than failing the run.
        if (block.chainid != 122) return;

        SolidPriceProvider implementation = new SolidPriceProvider();
        provider = SolidPriceProvider(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(SolidPriceProvider.initialize, (owner))
                )
            )
        );

        vm.startPrank(owner);
        // USDC as a hard peg. There is no market-price feed kind yet by design, which is exactly why
        // WETH - and therefore soETH - cannot be onboarded for real until one is added by upgrade.
        provider.setTokenConfig(
            USDC,
            PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: ERC20(USDC).decimals(),
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: 1e6,
                minPriceUsd: 0.97e6,
                maxPriceUsd: 1.03e6
            })
        );
        provider.setTokenConfig(
            SOUSD,
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: ERC20(SOUSD).decimals(),
                baseDecimals: ERC20(USDC).decimals(),
                // The real accountant enforces a ~1000s minimum update delay and +/-1% per update, so a
                // generous liveness window plus a wide absolute band is the right shape.
                maxStaleness: 7 days,
                source: SOUSD_ACCOUNTANT,
                baseAsset: USDC,
                pegPriceUsd: 0,
                minPriceUsd: 0.9e6,
                maxPriceUsd: 3e6
            })
        );
        vm.stopPrank();

        FuseRolesAuthority authority = new FuseRolesAuthority(owner, Authority(address(0)));
        module = new SolidCashModule(owner, address(authority), treasury, address(provider));
        lens = new SolidCashLens(address(module));

        vm.startPrank(owner);
        authority.setRoleCapability(SPENDER_ROLE, address(module), SolidCashModule.spend.selector, true);
        authority.setUserRole(spender, SPENDER_ROLE, true);

        module.setOrgCaps(25_000e6, 25_000e6, 250_000e6);
        module.setDefaultLimits(25_000e6, 250_000e6);
        module.setLimitRaiseDelay(1 hours);
        module.setDustFloor(0);
        module.allowSpendToken(SOUSD, 0, 0.9e6, 3e6);
        vm.stopPrank();

        safe = new MockSafe();
        safe.enableModule(address(module));
        deal(SOUSD, address(safe), 100_000e6);

        vm.prank(address(safe));
        module.registerSafe(0, 0, 0);
    }

    function _tokens(address token) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = token;
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = amount;
    }

    // ========================================= DECODING =========================================

    /// @dev The assertion that matters: the tuple we decode agrees with the contract's own getter.
    function test_fork_accountantStateDecodesCorrectly() external onFuse {
        (uint256 price, bool usable) = provider.priceUsd(SOUSD);

        assertTrue(usable, "live soUSD price should be usable");
        // USDC is pegged at exactly $1 here, so the composed price is the raw exchange rate.
        assertEq(price, IAccountant(SOUSD_ACCOUNTANT).getRate(), "exchangeRate decoded from wrong tuple slot");
        assertGt(price, 1e6, "soUSD is yield-bearing, so its rate should exceed 1.0");
    }

    function test_fork_soUsdAccountantIsDenominatedInUsdc() external onFuse {
        assertEq(IAccountant(SOUSD_ACCOUNTANT).vault(), SOUSD);
        assertEq(IAccountant(SOUSD_ACCOUNTANT).base(), USDC);
        assertEq(ERC20(USDC).decimals(), 6);
    }

    /**
     * @dev The soETH hazard, pinned against live state. Its accountant is denominated in WETH at 18
     *      decimals, not in dollars, so any code that treats an accountant's base as dollar-like is
     *      wrong by roughly the ETH price. This test exists to fail loudly if that assumption ever
     *      creeps back in.
     */
    function test_fork_soEthAccountantIsDenominatedInWethNotDollars() external onFuse {
        assertEq(IAccountant(SOETH_ACCOUNTANT).vault(), SOETH);
        assertEq(IAccountant(SOETH_ACCOUNTANT).base(), WETH);
        assertEq(ERC20(WETH).decimals(), 18, "soETH's base is an 18-decimal asset");
        assertEq(ERC20(SOETH).decimals(), 18);

        // The rate is ~1.008 WETH per soETH. Read as dollars that would be ~$1; it is really ~$3000.
        uint256 rate = IAccountant(SOETH_ACCOUNTANT).getRate();
        assertApproxEqRel(rate, 1.008e18, 0.05e18);

        // And it must be refused rather than mispriced while WETH has no configured feed.
        (, bool usable) = provider.priceUsd(SOETH);
        assertFalse(usable, "soETH must be unpriceable until WETH has a market feed");
    }

    /// @dev Composition through the real accountant, with WETH given a stand-in price.
    function test_fork_soEthComposesThroughWethWhenBasePriced() external onFuse {
        uint96 wethPriceUsd = 3_000e6;

        vm.startPrank(owner);
        provider.setTokenConfig(
            WETH,
            PriceFeedConfig({
                kind: PriceFeedKind.STABLE,
                tokenDecimals: 18,
                baseDecimals: 0,
                maxStaleness: 0,
                source: address(0),
                baseAsset: address(0),
                pegPriceUsd: wethPriceUsd,
                minPriceUsd: 100e6,
                maxPriceUsd: 20_000e6
            })
        );
        provider.setTokenConfig(
            SOETH,
            PriceFeedConfig({
                kind: PriceFeedKind.VEDA_ACCOUNTANT,
                tokenDecimals: 18,
                baseDecimals: 18,
                maxStaleness: 7 days,
                source: SOETH_ACCOUNTANT,
                baseAsset: WETH,
                pegPriceUsd: 0,
                minPriceUsd: 100e6,
                maxPriceUsd: 20_000e6
            })
        );
        vm.stopPrank();

        (uint256 price, bool usable) = provider.priceUsd(SOETH);

        assertTrue(usable);
        uint256 expected = (IAccountant(SOETH_ACCOUNTANT).getRate() * wethPriceUsd) / 1e18;
        assertEq(price, expected);
        assertGt(price, 3_000e6, "soETH must price in thousands, not ~1 dollar");
    }

    // ========================================= SPEND =========================================

    function test_fork_spendMovesRealSoUsd() external onFuse {
        uint256 amountUsd = 100e6;
        uint256 expectedShares = module.quoteTokenForUsd(SOUSD, amountUsd);

        vm.prank(spender);
        uint256 moved = module.spend(address(safe), bytes32("fork-tx-1"), _tokens(SOUSD), _amounts(amountUsd))[0];

        assertEq(moved, expectedShares);
        assertEq(ERC20(SOUSD).balanceOf(treasury), expectedShares);
        // soUSD trades above $1, so settling $100 must cost strictly fewer than 100 shares.
        assertLt(moved, 100e6);
    }

    function test_fork_lensReadsLiveState() external onFuse {
        SolidCashLens.SpendAvailability memory data = lens.availableToSpend(address(safe));

        assertTrue(data.moduleEnabled);
        assertTrue(data.registered);
        assertFalse(data.anyPriceUnusable);
        assertEq(data.perTokenBreakdown.length, 1);
        assertEq(data.perTokenBreakdown[0].token, SOUSD);
        assertEq(data.perTokenBreakdown[0].balance, 100_000e6);
        assertTrue(data.perTokenBreakdown[0].priceUsable);
        assertEq(data.spendableUsd, 25_000e6); // balance is ample, so the daily cap binds
        assertEq(data.blockNumber, block.number);
    }
}
