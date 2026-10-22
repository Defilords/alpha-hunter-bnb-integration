# Alpha Hunter on BNB Chain

Alpha Hunter by [DefiLords](https://defilords.finance) is an on-chain trading product on **BNB Smart Chain** with two parts:

- **Autopilot**: a share-based USDT vault (`AlphaSelectVault`). Users deposit USDT and receive vault shares; an automated
  keeper trades a small allowlist of BSC tokens on PancakeSwap on the vault's behalf, inside hard limits enforced by the contract.
- **Guardrail**: a self-directed position manager (`PositionManager`). Users open their own token positions from USDT and set
  their own stop-loss, take-profit and trailing rules; a keeper closes a position only when one of the owner's own triggers fires.
  The owner can always close or withdraw the tokens themselves.

Both use an on-chain `PriceOracle` (Chainlink first, PancakeSwap V3 TWAP as a cross-check) and are governed by a Gnosis Safe
through a 48-hour timelock.

Website: <https://alphahunter.defilords.finance>

This repository is the public, BNB Chain-facing part of Alpha Hunter: the **exact verified source code of the deployed
contracts**, the network configuration, documentation, and read-only examples. The off-chain trading engine and keeper are
not included.

## Deployed contracts (BNB Smart Chain mainnet, chain id 56)

| Contract | Address | Type | Source verification |
|---|---|---|---|
| Autopilot vault (`AlphaSelectVault`) | [`0xf3CEAeA2dd8b869Fe2FbA6fD1830fa822aade80b`](https://bscscan.com/address/0xf3CEAeA2dd8b869Fe2FbA6fD1830fa822aade80b) | ERC1967 proxy (UUPS) | [Sourcify](https://sourcify.dev/#/lookup/0xf3CEAeA2dd8b869Fe2FbA6fD1830fa822aade80b) |
| ↳ vault implementation | [`0x47C8C256c52EE868F6C331D82B7f8FAbd6F931C5`](https://bscscan.com/address/0x47C8C256c52EE868F6C331D82B7f8FAbd6F931C5) | logic | [Sourcify](https://sourcify.dev/#/lookup/0x47C8C256c52EE868F6C331D82B7f8FAbd6F931C5) |
| Price oracle (`PriceOracle`) | [`0x9a037Dfa8049782F61d402B5c2a3dD172BDAB933`](https://bscscan.com/address/0x9a037Dfa8049782F61d402B5c2a3dD172BDAB933) | ERC1967 proxy (UUPS) | [Sourcify](https://sourcify.dev/#/lookup/0x9a037Dfa8049782F61d402B5c2a3dD172BDAB933) |
| ↳ oracle implementation | [`0x57192c6D84c73b8fEdE3d440228747D1A7E6D45a`](https://bscscan.com/address/0x57192c6D84c73b8fEdE3d440228747D1A7E6D45a) | logic | [Sourcify](https://sourcify.dev/#/lookup/0x57192c6D84c73b8fEdE3d440228747D1A7E6D45a) |
| Guardrail (`PositionManager`) | [`0x05C9388A720313CAf3d3dF0ECcb51595b75639Fa`](https://bscscan.com/address/0x05C9388A720313CAf3d3dF0ECcb51595b75639Fa) | non-upgradeable | [Sourcify](https://sourcify.dev/#/lookup/0x05C9388A720313CAf3d3dF0ECcb51595b75639Fa) |

Governance: timelock [`0x6FDB746c27fA59b0F875275d3a9bBDbC0A00eB36`](https://bscscan.com/address/0x6FDB746c27fA59b0F875275d3a9bBDbC0A00eB36)
(48 h minimum delay), proposed and executed by the Safe [`0x1Da5bC3C9937885086F185095BE42845C0DE4Eba`](https://bscscan.com/address/0x1Da5bC3C9937885086F185095BE42845C0DE4Eba) (2 of 3).
Full details: [`docs/contracts.md`](docs/contracts.md). Machine-readable: [`config/bsc-mainnet.json`](config/bsc-mainnet.json).

## Verify the code yourself

The sources in [`contracts/`](contracts) were downloaded from the Sourcify verification records, and
[`contracts/foundry.toml`](contracts/foundry.toml) carries the exact compiler settings of the deployments
(solc 0.8.24, optimizer 153 runs, via-IR, EVM `cancun`). Building reproduces the deployed bytecode, metadata included:

```bash
cd contracts
forge build
cast code 0x05C9388A720313CAf3d3dF0ECcb51595b75639Fa --rpc-url https://bsc-dataseed.bnbchain.org
# compare with out/PositionManager.sol/PositionManager.json -> deployedBytecode
# (immutables: USDT and WBNB; the vault also links the ValuationLib library)
```

## Read the live contracts

```bash
cd examples
npm install
npm run read        # optional: RPC_URL=<your BSC RPC> npm run read
```

Prints the vault's assets, share price, deposit cap and allowlist state, the oracle's Chainlink prices, Guardrail's settings
and the governance setup. Read-only: no wallet, no keys, no transactions.

## Documentation

- [`docs/architecture.md`](docs/architecture.md): how the on-chain and off-chain parts fit together
- [`docs/autopilot-vault.md`](docs/autopilot-vault.md): deposits, redemptions and the keeper's limits
- [`docs/guardrail.md`](docs/guardrail.md): positions, triggers, fees and the owner's exits
- [`docs/governance.md`](docs/governance.md): Safe, timelock, roles and emergency controls
- [`docs/contracts.md`](docs/contracts.md): addresses, roles and dependencies
- [`SECURITY.md`](SECURITY.md): audit status and how to report a vulnerability

## Status

- Autopilot vault: live since 2 Oct 2026 in a staged launch: deposit allowlist on, $2,000 deposit cap.
- Guardrail: deployed 21 Oct 2026. Opening positions needs the oracle's TWAP sources for CAKE and WBNB, registered through the
  timelock; until then every open is refused by the contract. Launch is limited to allowlisted wallets, CAKE only, 10 to 500 USDT
  per position.
- **No external audit yet.** Do not deposit more than you can afford to lose. See [`SECURITY.md`](SECURITY.md).

## Licensing

The Solidity sources keep their own SPDX licence headers (MIT for the Alpha Hunter contracts and for OpenZeppelin).
No licence is granted for the other contents of this repository.
