# Architecture

```
            users (own wallets)                                  DefiLords operations
   ┌─────────────────┴──────────────────┐                ┌──────────────┴───────────────┐
   │ deposit / redeem      open / close │                │ keeper bot (off-chain)        │  Gnosis Safe (2 of 3)
   ▼                                    ▼                │  - settles vault queues       │        │ proposes / executes
┌──────────────────┐            ┌────────────────────┐   │  - trades the vault           │        ▼
│ AlphaSelectVault │            │  PositionManager   │◄──┤  - pokes peaks, closes fired  │  TimelockController (48 h)
│ (Autopilot)      │◄───────────┤  (Guardrail)       │   │    Guardrail triggers         │        │ DEFAULT_ADMIN_ROLE
│ USDT, shares     │  separate  │  per-user positions│   └───────────────────────────────┘        ▼
└───────┬──────────┘  contracts └─────────┬──────────┘                              vault · oracle · PositionManager
        │ prices                          │ prices
        ▼                                 ▼
┌───────────────────────────────────────────────────┐
│ PriceOracle: Chainlink feeds (primary)             │
│              PancakeSwap V3 TWAP (cross-check)     │
└───────────────────────────────────────────────────┘
        swaps: PancakeSwap V2 router / V3 SwapRouter
```

## On-chain (this repository)

- **AlphaSelectVault** holds pooled USDT and the tokens it buys. Deposits and redemptions are two-step (request, then settle at
  the settlement-time NAV), which removes the advantage of timing a deposit around a price move. Only the keeper can trade, only
  into allowlisted tokens and through allowlisted routers, within per-trade, per-day and slippage limits checked by the contract.
- **PositionManager** holds each user's own positions separately. Users open and close their own positions; the keeper can only
  act when a user's own trigger has fired, and only through the same price checks.
- **PriceOracle** answers prices in USD: Chainlink first, with a PancakeSwap V3 TWAP as a manipulation-resistant cross-check
  where configured, plus staleness and divergence guards.

## Off-chain (not in this repository)

- The **keeper** (Node.js) runs on a fixed cycle: reads market data, scores candidates, sends vault trades within the contract's
  limits, settles deposit and redemption queues, and, for Guardrail, pokes trailing peaks and closes positions whose trigger fired.
  It holds only `KEEPER_ROLE`: it cannot move funds out, change settings, or pause/unpause.
- The **website** (Next.js) reads chain state over public RPC and asks the user's own wallet to sign every user action.

## Trust boundaries

| Actor | Can | Cannot |
|---|---|---|
| User | deposit/redeem (vault); open, edit triggers, close, withdraw in kind (Guardrail) | touch other users' positions |
| Keeper | settle queues, trade within limits (vault); poke peaks, close fired triggers (Guardrail) | withdraw funds, change settings, add tokens |
| Safe (2 of 3) | pause, guardian actions, propose timelock operations | act as admin without the 48 h delay |
| Timelock (48 h) | admin actions: allowlists, limits, oracle config, upgrades (vault, oracle) | act faster than 48 h |
