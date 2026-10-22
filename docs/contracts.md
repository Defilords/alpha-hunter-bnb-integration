# Contracts and dependencies (BNB Smart Chain mainnet)

| Name | Address | Notes |
|---|---|---|
| AlphaSelectVault (proxy) | `0xf3CEAeA2dd8b869Fe2FbA6fD1830fa822aade80b` | created 2 Oct 2026 |
| AlphaSelectVault (implementation) | `0x47C8C256c52EE868F6C331D82B7f8FAbd6F931C5` | current logic; links `ValuationLib` |
| PriceOracle (proxy) | `0x9a037Dfa8049782F61d402B5c2a3dD172BDAB933` | created 2 Oct 2026 |
| PriceOracle (implementation) | `0x57192c6D84c73b8fEdE3d440228747D1A7E6D45a` | |
| PositionManager | `0x05C9388A720313CAf3d3dF0ECcb51595b75639Fa` | created 21 Oct 2026, block 128,904,845 |
| TimelockController | `0x6FDB746c27fA59b0F875275d3a9bBDbC0A00eB36` | 48 h minimum delay |
| Gnosis Safe | `0x1Da5bC3C9937885086F185095BE42845C0DE4Eba` | 2 of 3 |
| Keeper | `0x47f2BC2E4Ef3025Ba6Eb9bD83b2EFe763Ff47Ed4` | `KEEPER_ROLE` only |

External dependencies:

| Dependency | Address |
|---|---|
| USDT (BSC) | `0x55d398326f99059fF775485246999027B3197955` |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| CAKE | `0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82` |
| PancakeSwap V2 router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| PancakeSwap V3 SwapRouter | `0x1b81D678ffb9C0263b24A97847620C99d213eB14` |
| Chainlink price feeds | per token, registered on the oracle (`feeds(token)`) |

All five Alpha Hunter addresses above are source-verified on Sourcify (exact match, except the vault implementation: match).
