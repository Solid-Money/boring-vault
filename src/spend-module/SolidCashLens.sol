// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {SolidCashModule} from "./SolidCashModule.sol";
import {SpendingLimit} from "./libraries/SpendingLimitLib.sol";

/**
 * @title SolidCashLens
 * @notice Read-only aggregator that answers "may this card transaction proceed, for how much, and out
 *         of which assets?" in a single `eth_call`.
 * @dev Exists purely for latency. Wirex's External Authorization contract gives us a 300ms target and a
 *      500ms hard timeout for the whole authorize decision, and a timeout is treated as a decline.
 *      Reading N token balances plus N prices plus limits over separate calls cannot fit that budget,
 *      so the aggregation is pushed on-chain and the hot path makes exactly one round trip to a
 *      co-located Fuse node. The multi-token move is what makes this decisive rather than merely
 *      convenient: the number of reads now grows with the allowlist.
 *
 *      Correctness, not just speed, is the reason this is a contract rather than a backend helper:
 *      every field is computed by the same `SolidCashModule` view functions the module's own `spend`
 *      write path uses - including the module's own price band, not the raw price provider - so an
 *      authorization can never approve an amount that `spend` would then reject. The lens holds no
 *      logic of its own and no state.
 *
 *      `perTokenBreakdown` is what lets the backend choose *which* assets to draw from (idle stables
 *      before yield-bearing positions) and lets a decline name the asset that fell short, without a
 *      second round trip.
 *
 *      `blockNumber` is the field that makes the caller's in-flight accounting race-free. Debits the
 *      backend has broadcast but that are not yet mined are still reflected in the balances here, so
 *      the caller must subtract any pending debit whose transaction either has no block yet or landed
 *      in a block after `blockNumber`. Past that point the on-chain balance already reflects it and
 *      subtracting again would double-count. This is the one part of the decision the chain cannot
 *      answer.
 */
contract SolidCashLens {
    /**
     * @notice One allowlisted asset's contribution to a Safe's spending power.
     * @param token Asset address
     * @param balance Raw balance held by the Safe
     * @param priceUsd Price the *module* would accept, 6 decimals. Zero when unusable
     * @param priceUsable False when the feed is down, stale, or outside the module's own band
     * @param valueUsd Haircut USD value of `balance`. Zero when the price is unusable
     */
    struct TokenAvailability {
        address token;
        uint256 balance;
        uint256 priceUsd;
        bool priceUsable;
        uint256 valueUsd;
    }

    /**
     * @notice Everything the authorize path needs about one Safe, as of `blockNumber`.
     * @param moduleEnabled Module still enabled on the Safe (a user revoking is instant consent withdrawal)
     * @param registered Safe has opted into card spending
     * @param modulePaused Global guardian pause
     * @param safePausedFlag Per-Safe guardian pause (arrears, fraud hold)
     * @param anyPriceUnusable At least one allowlisted asset could not be priced - a decline reason and
     *        an ops signal, since it means quoted power is understated rather than wrong
     * @param spendableUsd USD the module would approve right now, before in-flight subtraction
     * @param limitRemainingUsd Headroom under the Safe's caps and the live org ceilings
     * @param maxPerTxUsd Hard cap on any single debit
     * @param perTokenBreakdown Per-asset detail, for sweep token selection and decline reasons
     * @param limit Full limit state with matured transitions applied
     * @param blockNumber Block this view was evaluated at - anchor for in-flight subtraction
     * @param blockTimestamp Timestamp of that block, for node-liveness checks
     */
    struct SpendAvailability {
        bool moduleEnabled;
        bool registered;
        bool modulePaused;
        bool safePausedFlag;
        bool anyPriceUnusable;
        uint256 spendableUsd;
        uint256 limitRemainingUsd;
        uint256 maxPerTxUsd;
        TokenAvailability[] perTokenBreakdown;
        SpendingLimit limit;
        uint256 blockNumber;
        uint256 blockTimestamp;
    }

    /// @notice The module this lens reads. Immutable, so a lens can never drift onto other logic.
    SolidCashModule public immutable module;

    error InvalidInput();

    constructor(address _module) {
        if (_module == address(0)) revert InvalidInput();
        module = SolidCashModule(_module);
    }

    /**
     * @notice The authorize path's single read.
     * @dev Every gate is reported rather than collapsed into one boolean, so a decline can be given an
     *      accurate reason and ops can tell a paused module apart from an empty Safe or a dead feed.
     *      `spendableUsd` is already 0 whenever any gate fails.
     */
    function availableToSpend(address safe) public view returns (SpendAvailability memory data) {
        data.registered = module.isRegistered(safe);
        data.modulePaused = module.isPaused();
        data.safePausedFlag = module.safePaused(safe);
        data.moduleEnabled = module.isModuleEnabledOn(safe);

        data.spendableUsd = module.spendableUsd(safe);
        data.limitRemainingUsd = module.maxCanSpendUsd(safe);
        data.maxPerTxUsd = module.maxPerTxUsd();
        data.limit = module.applicableSpendingLimit(safe);

        (
            address[] memory tokens,
            uint256[] memory balances,
            uint256[] memory prices,
            uint256[] memory valuesUsd
        ) = module.perTokenSpendable(safe);

        data.perTokenBreakdown = new TokenAvailability[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            bool priceUsable = prices[i] != 0;
            // A held asset we cannot price is the case worth surfacing: it silently understates the
            // user's power, so it looks like "insufficient funds" to them and like nothing at all to us.
            if (!priceUsable && balances[i] != 0) data.anyPriceUnusable = true;

            data.perTokenBreakdown[i] = TokenAvailability({
                token: tokens[i],
                balance: balances[i],
                priceUsd: prices[i],
                priceUsable: priceUsable,
                valueUsd: valuesUsd[i]
            });
        }

        data.blockNumber = block.number;
        data.blockTimestamp = block.timestamp;
    }

    /**
     * @notice `availableToSpend` for many Safes in one call, for reconciliation and ops sweeps.
     * @dev Not for the authorize path, which only ever cares about one Safe and must keep its calldata
     *      and gas bounded.
     */
    function availableToSpendBatch(address[] calldata safes)
        external
        view
        returns (SpendAvailability[] memory data)
    {
        data = new SpendAvailability[](safes.length);
        for (uint256 i = 0; i < safes.length; ++i) {
            data[i] = availableToSpend(safes[i]);
        }
    }

    /**
     * @notice Dry-run of a specific debit, including `txId` replay state.
     * @dev Straight passthrough to the module so the decision logic has exactly one home.
     */
    function canSpend(address safe, bytes32 txId, address[] calldata tokens, uint256[] calldata amountsUsd)
        external
        view
        returns (bool, string memory)
    {
        return module.canSpend(safe, txId, tokens, amountsUsd);
    }
}
