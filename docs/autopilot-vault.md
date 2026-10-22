# Autopilot vault (`AlphaSelectVault`)

Address: `0xf3CEAeA2dd8b869Fe2FbA6fD1830fa822aade80b` (ERC1967 proxy, UUPS). Asset: BSC USDT (18 decimals).

## Deposits and redemptions

| Step | Function | Who |
|---|---|---|
| Request a deposit (USDT pulled into the queue) | `requestDeposit(assets)` | any allowlisted depositor |
| Cancel before settlement | `cancelDepositRequest(id)` | the depositor |
| Settle deposits at settlement-time NAV (at least `MIN_DEPOSIT_SETTLE_DELAY` = 10 minutes after the request) | `settleDeposits(max)` | keeper or admin |
| Request a redemption (shares into the queue) | `requestRedeem(shares)` | any shareholder |
| Settle redemptions at settlement-time NAV | `settleRedemptions(max)` | keeper or admin |
| Force-settle a stale redemption after `MAX_REDEMPTION_WAIT` = 7 days (14 days while a held token cannot be priced) | `forceSettleStale(id)` | **anyone** |

The permissionless `forceSettleStale` is the backstop: a redemption cannot be held indefinitely by an inactive keeper.

## What the keeper may do

Trades go through `executeSwap` (PancakeSwap V2) and `executeSwapV3` (V3), `KEEPER_ROLE` only. The contract enforces, on every
trade: allowlisted token and router, a maximum position size, a maximum slippage, a daily trade count and an oracle-based
minimum output. Current live values (read them with `examples/read-onchain.mjs` or BscScan):

| Limit | Value |
|---|---|
| Deposit cap | 2,000 USDT, deposit allowlist on (staged launch) |
| Max position | 400 USDT |
| Max slippage per trade | 3% |
| Max trades per day | 20 |
| Max single exit | 500 USDT |

Tradable tokens are whatever `tokenAllowed(token)` returns true for; adding one is a 48-hour timelock operation.

## Emergency controls

- `pauseTrading()`: the Safe can stop new trades immediately; only the timelock can unpause.
- `emergencyRevokeKeeper(account)`: the Safe can remove the keeper's role immediately.
- `adminEmergencyExitV3(...)`: the Safe (guardian) or the timelock can sell a holding back to USDT, bounded by an oracle floor
  with at most `emergencyExitMaxSlippageBps` = 5% slippage.

## Fees

Performance-fee tiers are defined as constants in `AlphaSelectVault.sol` (`FEE_TIER_*`); see the source for exactly how and
when they apply.
