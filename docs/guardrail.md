# Guardrail (`PositionManager`)

Address: `0x05C9388A720313CAf3d3dF0ECcb51595b75639Fa` (non-upgradeable). Quote asset: BSC USDT.

A user's position belongs to the user. The contract holds the tokens, but only the owner can close it early or withdraw it;
the keeper can only close it when one of the **owner's own** triggers has fired.

## User actions

| Function | What it does |
|---|---|
| `openPosition(token, usdtIn, route, minTokensOut, triggers, deadline)` | swaps USDT into an allowed token via an allowed PancakeSwap router and records the position with its triggers |
| `updateTriggers(id, triggers)` | owner changes stop-loss, take-profit and trailing settings |
| `closePosition(id, route, minUsdtOut, deadline)` | owner sells back to USDT at any time (no oracle needed) |
| `withdrawInKind(id)` | owner takes the tokens themselves: no sale, no fee, no price check, works even while opening is paused |

## Triggers (all optional)

| Trigger | Fires when |
|---|---|
| Stop-loss | price ≤ the owner's stop price |
| Take-profit | price ≥ the owner's target price |
| Trailing stop | price falls a set % below the highest price seen |
| Trailing profit | once the gain reaches an activation level, the exit trails the peak gain by a set % and never drops below a locked minimum gain |

The contract validates triggers (for example the lock must be below the activation), caps each at 50%, and caps the
slippage allowed on an automatic close at 3%. `triggerStatus(id)` returns whether a position's trigger has fired, and why.

## Pricing and safety checks

Every open and every automatic close prices the token through `PriceOracle` with **both** a Chainlink feed and a PancakeSwap V3
TWAP: if they disagree beyond a tolerance, or the Chainlink price is older than the allowed age, the contract refuses. An
automatic close must also receive at least the oracle value minus the owner's slippage limit. A manipulated pool can make a
close fail, but cannot make it pay out less than that floor. The owner's `closePosition` and `withdrawInKind` do not depend on
the oracle, so a broken price feed can never trap a position.

## Fees and limits (launch values)

| Item | Value |
|---|---|
| Open fee | 0.5% of the USDT put in (hard ceiling 3% in the contract; raises are timelocked and delayed) |
| Close fee | 0.5% of the proceeds on a profitable close, never more than the profit; **no close fee on a loss** |
| Keeper gas repayment | at most 0.10 USDT per position, only on keeper actions |
| Position size | 10 to 500 USDT; total open across all users 10,000 USDT |
| Tokens | CAKE only at launch |
| Access | user allowlist on (beta) |

Fee raises are delayed (scheduled, then applied later); fee cuts are immediate. The guardian (Safe) can pause **opening**;
closes and withdrawals are never paused.
