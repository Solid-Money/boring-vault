/**
 * Deployment parameters for the Solid card spend module (SolidPriceProvider +
 * SolidCashModule + SolidCashLens).
 *
 * Phase 1 scope is soUSD on Fuse only. USDC is configured in the price provider not
 * because it is spendable, but because soUSD's accountant is denominated in it and the
 * provider prices a Veda share as `exchangeRate x price(baseAsset)`.
 *
 * The numbers below mirror `test/spend-module/SolidCashModuleFuseFork.t.sol`, which is the
 * only configuration exercised against the live Fuse contracts.
 */

const { ethers } = require('hardhat')

/** 6-decimal USD, matching SolidPriceProvider.PRICE_DECIMALS. */
const usd = (n) => ethers.utils.parseUnits(String(n), 6)

const HOUR = 60 * 60
const DAY = 24 * 60 * 60

/**
 * The multiple the app derives a monthly cap from a chosen daily one
 * (MONTHLY_LIMIT_MULTIPLIER in solid-ui's constants/cardSpendModule.ts).
 *
 * It has to be reflected here, because the app filters a daily preset out unless
 * `daily * this <= maxMonthlyLimitUsd`. A monthly ceiling below the multiple of the daily
 * one does not merely cap the month — it makes the top daily options *disappear from the
 * picker*, with no error anywhere to explain why.
 */
const MONTHLY_LIMIT_MULTIPLIER = 10

/**
 * The org-wide daily ceiling — and, deliberately, the per-transaction cap as well. Named
 * once so the two cannot drift: see `maxPerTxUsd` below for why they are the same number.
 */
const FUSE_MAX_DAILY_LIMIT_USD = usd(25_000)
const FUSE_MAX_MONTHLY_LIMIT_USD = FUSE_MAX_DAILY_LIMIT_USD.mul(MONTHLY_LIMIT_MULTIPLIER)

const fuse = {
  // ── External addresses (Fuse, chainId 122) ──────────────────────────────────
  // soUSD: the LayerZero OFT share token users hold and the only spendable asset in phase 1.
  soUsd: '0x75333830E7014e909535389a6E5b0C02aA62ca27',
  // Reached via the Fuse soUSD teller's `accountant()`. base = USDC-on-Fuse, 6 decimals.
  soUsdAccountant: '0x47A5e832E1178726dd13AdD762774A704878AD98',
  // USDC on Fuse — soUSD's accountant base asset.
  usdc: '0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9',

  // ── Roles and ownership ─────────────────────────────────────────────────────
  // Every `set*` on the module and the price provider's PRICE_ADMIN/UPGRADER roles should
  // end up here. Must be the timelocked multisig in production.
  owner: '0x3B694d634981Ace4B64a27c48bffe19f1447779B',

  // Backend sweep engine key (KMS in production). Gets SPENDER_ROLE — may call `spend`
  // and nothing else.
  spender: '0x0000000000000000000000000000000000000000', // TODO: fill before deploying

  // Holds PRICE_ADMIN_ROLE on the price provider — day-to-day feed configuration. Should
  // NOT be the same key as `owner`, which holds UPGRADER_ROLE: replacing the implementation
  // over live user funds and adjusting a feed are different levels of authority. Falls back
  // to `owner` when empty, with a warning.
  priceAdmin: '',

  // Pause key, deliberately separate from the spender. Gets GUARDIAN_ROLE.
  guardian: '0x0000000000000000000000000000000000000000', // TODO: fill before deploying

  // The only address `spend` can ever send to. Immutable once the module is deployed —
  // getting this wrong means a redeploy and a re-consent migration for every user.
  settlementTreasury: '0x0000000000000000000000000000000000000000', // TODO: fill before deploying

  // Reuse an existing FuseRolesAuthority instead of deploying a dedicated one. Leaving
  // this empty deploys a fresh authority in step 02, which is the recommended path: the
  // vault's authority is owned by the vault's owner and mixing the two would give that
  // owner the spend role.
  existingAuthority: '',

  // ── Role IDs in the spend module's FuseRolesAuthority ───────────────────────
  roles: {
    SPENDER: 1,
    GUARDIAN: 2,
  },

  // ── Module configuration ────────────────────────────────────────────────────
  module: {
    // setOrgCaps(maxPerTxUsd, maxDailyLimitUsd, maxMonthlyLimitUsd).
    // Requires maxDailyLimitUsd <= maxMonthlyLimitUsd. These are live ceilings clamping
    // every Safe on every read, so lowering them is the staged-rollout throttle.
    //
    // maxPerTxUsd is set *equal to* the daily ceiling so that it can never be the binding
    // constraint: the module clamps every Safe's daily headroom to maxDailyLimitUsd, so
    // anything the rolling windows allow is already at or under this. That leaves the daily
    // limit as the only cap a cardholder has to reason about.
    //
    // Never 0. The module checks `totalUsd > maxPerTxUsd`, so 0 rejects every spend, while
    // the backend's authorize path reads 0 as "no per-transaction cap" and would approve
    // what the module then refuses. Lowering it below the daily ceiling is still a live
    // throttle if one is ever wanted.
    maxPerTxUsd: FUSE_MAX_DAILY_LIMIT_USD,
    maxDailyLimitUsd: FUSE_MAX_DAILY_LIMIT_USD,
    maxMonthlyLimitUsd: FUSE_MAX_MONTHLY_LIMIT_USD,

    // setDefaultLimits — applied when a Safe registers passing 0.
    //
    // Equal to the ceilings, matching the app's activation default: a cardholder who never
    // opens the limits sheet gets the full grant rather than a cap they would later hit at
    // a till. One activation signature therefore lets the module debit this much a day from
    // that Safe. Lowering it is one owner transaction and immediate.
    defaultDailyLimitUsd: FUSE_MAX_DAILY_LIMIT_USD,
    defaultMonthlyLimitUsd: FUSE_MAX_MONTHLY_LIMIT_USD,

    // setLimitRaiseDelay — the window in which an unintended limit increase can be
    // cancelled. Capped at MAX_LIMIT_RAISE_DELAY (30 days) by the contract.
    //
    // One hour, not one day. The delay only gates *raises*, and it is paid by the Safes
    // already registered under a lower cap: their stored limit is the binding one and no
    // admin can lift it, so a user who outgrows it signs a raise and then cannot spend the
    // new amount until this elapses. A day of that is a card that declines for a day. An
    // hour still leaves a real window to cancel a raise nobody intended.
    limitRaiseDelay: 1 * HOUR,

    // setDustFloor — quote-only reserve, subtracted from `spendableUsd` so a quote can
    // never round up into an amount `spend` cannot actually collect.
    dustFloorUsd: usd(0),

    // allowSpendToken(token, haircutBps, minPriceUsd, maxPriceUsd).
    //
    // The band is the module's own, checked independently of the (upgradeable) price
    // provider — it is what makes a hostile or buggy provider upgrade survivable, so keep
    // it as tight as the asset honestly allows.
    //
    // haircutBps is quote-only: it makes `spendableUsd` more conservative and does not
    // limit what `spend` collects. 0 is right for a stable-denominated share; a volatile
    // asset needs a real buffer here.
    spendTokens: [
      {
        name: 'soUSD',
        address: '0x75333830E7014e909535389a6E5b0C02aA62ca27',
        haircutBps: 0,
        minPriceUsd: usd(0.9),
        maxPriceUsd: usd(3),
      },
    ],
  },

  // ── Price feeds, in configuration order ─────────────────────────────────────
  // Order matters: a VEDA_ACCOUNTANT feed reverts with BaseAssetNotConfigured unless its
  // base asset already has a feed, so bases come first.
  priceFeeds: [
    {
      name: 'USDC',
      token: '0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9',
      config: {
        kind: 1, // PriceFeedKind.STABLE
        tokenDecimals: 6,
        baseDecimals: 0,
        maxStaleness: 0,
        source: ethers.constants.AddressZero,
        baseAsset: ethers.constants.AddressZero,
        pegPriceUsd: usd(1),
        minPriceUsd: usd(0.97),
        maxPriceUsd: usd(1.03),
      },
    },
    {
      name: 'soUSD',
      token: '0x75333830E7014e909535389a6E5b0C02aA62ca27',
      config: {
        kind: 2, // PriceFeedKind.VEDA_ACCOUNTANT
        tokenDecimals: 6,
        baseDecimals: 6, // USDC — NOT soUSD's decimals. exchangeRate is quoted in base units.
        // The live accountant enforces a ~1000s minimum update delay and +/-1% per update,
        // so a generous liveness window plus a wide absolute band is the right shape.
        maxStaleness: 7 * DAY,
        source: '0x47A5e832E1178726dd13AdD762774A704878AD98',
        baseAsset: '0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9',
        pegPriceUsd: 0,
        minPriceUsd: usd(0.9),
        maxPriceUsd: usd(3),
      },
    },
  ],
}

const configs = { fuse }

function getConfig(networkName) {
  const config = configs[networkName]
  if (!config) {
    throw new Error(
      `No spend-module deployment config for network "${networkName}". Known: ${Object.keys(configs).join(', ')}`
    )
  }
  return config
}

module.exports = { getConfig, usd, DAY }
