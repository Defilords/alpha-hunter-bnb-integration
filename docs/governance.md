# Governance and roles

| Role | Holder | On |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | TimelockController `0x6FDB746c27fA59b0F875275d3a9bBDbC0A00eB36` (48 h minimum delay) | vault, oracle, PositionManager |
| Timelock proposer / executor | Gnosis Safe `0x1Da5bC3C9937885086F185095BE42845C0DE4Eba` (2 of 3) | timelock |
| `PAUSER_ROLE`, `GUARDIAN_ROLE` | the Safe (directly, no delay) | vault / PositionManager |
| `FEE_MANAGER_ROLE` (can only lower the fee) | the Safe | PositionManager |
| `KEEPER_ROLE` | `0x47f2BC2E4Ef3025Ba6Eb9bD83b2EFe763Ff47Ed4` | vault, PositionManager |

The deployer EOAs hold no roles. Every admin change (token or router allowlists, limits, oracle configuration, contract
upgrades for the vault and oracle) is scheduled by the Safe on the timelock, is visible on-chain for 48 hours, and only then
can be executed. Emergency actions that only reduce risk (pause, revoking the keeper, the bounded emergency exit) are available to
the Safe immediately.

The PositionManager is not upgradeable.
