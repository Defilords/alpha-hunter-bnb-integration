# Security

## Status

- **No external audit has been completed yet.** The contracts have an internal Foundry test suite (unit, invariant and
  mainnet-fork tests) and internal static analysis, which are not a substitute for an independent audit.
- Launch is staged: the vault has a deposit allowlist and a 2,000 USDT cap; Guardrail has a user allowlist, CAKE only and
  10 to 500 USDT per position.
- All deployed sources are verified on Sourcify and reproduced in this repository (see README).

## Controls that limit the impact of a bug

- Admin actions go through a 48-hour timelock run by a 2-of-3 Gnosis Safe.
- The keeper cannot withdraw funds or change settings; its trades are bounded on-chain.
- The Safe can pause vault trading or Guardrail opening, and revoke the keeper, immediately.
- Guardrail owners can always `closePosition` or `withdrawInKind`, including while opening is paused or the oracle is down.
- Redemptions that the keeper does not settle can be force-settled by anyone after 7 days.

## Reporting a vulnerability

Please email **admindefylords@protonmail.com** with a description and, if possible, a proof of concept. Do not test against
mainnet funds, and do not disclose publicly until we have had a reasonable time to respond.
