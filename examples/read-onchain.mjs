// Read-only tour of the Alpha Hunter contracts on BNB Smart Chain mainnet. No wallet, no keys, no transactions.
//   cd examples && npm install && npm run read          (optional: RPC_URL=<your BSC RPC> npm run read)
import { readFileSync } from "node:fs";
import { ethers } from "ethers";

const cfg = JSON.parse(readFileSync(new URL("../config/bsc-mainnet.json", import.meta.url)));
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL || cfg.publicRpc, cfg.chainId, { staticNetwork: true });
const C = cfg.contracts;
const usd = (wad) => Number(ethers.formatUnits(wad, 18)).toLocaleString("en-US", { maximumFractionDigits: 4 });

const vault = new ethers.Contract(C.alphaSelectVault.address, [
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)",
  "function depositCap() view returns (uint256)",
  "function depositAllowlistEnabled() view returns (bool)",
  "function tradingPaused() view returns (bool)",
  "function tokenAllowed(address) view returns (bool)",
], provider);

const oracle = new ethers.Contract(C.priceOracle.address, [
  "function hasFeed(address) view returns (bool)",
  "function getChainlinkPriceWad(address) view returns (uint256)",
], provider);

const pm = new ethers.Contract(C.positionManager.address, [
  "function tradeFeeBps() view returns (uint16)",
  "function minPositionUsdt() view returns (uint256)",
  "function maxPositionUsdt() view returns (uint256)",
  "function totalOpenCapUsdt() view returns (uint256)",
  "function totalOpenUsdt() view returns (uint256)",
  "function userAllowlistEnabled() view returns (bool)",
  "function openingPaused() view returns (bool)",
  "function tokenAllowed(address) view returns (bool)",
  "function nextPositionId() view returns (uint256)",
  "function hasRole(bytes32,address) view returns (bool)",
], provider);

const timelock = new ethers.Contract(cfg.governance.timelock, ["function getMinDelay() view returns (uint256)"], provider);

const block = await provider.getBlockNumber();
console.log(`BNB Smart Chain mainnet, block ${block}\n`);

console.log("Autopilot vault (AlphaSelectVault)", C.alphaSelectVault.address);
console.log("  total assets (USDT):     ", usd(await vault.totalAssets()));
console.log("  share price (USDT/share):", usd(await vault.convertToAssets(ethers.parseUnits("1", 18))));
console.log("  deposit cap (USDT):      ", usd(await vault.depositCap()));
console.log("  deposit allowlist on:    ", await vault.depositAllowlistEnabled());
console.log("  trading paused:          ", await vault.tradingPaused());
for (const [sym, addr] of Object.entries({ CAKE: cfg.tokens.CAKE, WBNB: cfg.tokens.WBNB })) {
  console.log(`  ${sym} tradable by the vault:`, await vault.tokenAllowed(addr));
}

console.log("\nPrice oracle (PriceOracle)", C.priceOracle.address);
for (const [sym, addr] of Object.entries({ CAKE: cfg.tokens.CAKE, WBNB: cfg.tokens.WBNB })) {
  console.log(`  ${sym} Chainlink price (USD):`, (await oracle.hasFeed(addr)) ? usd(await oracle.getChainlinkPriceWad(addr)) : "no feed");
}

console.log("\nGuardrail (PositionManager)", C.positionManager.address);
console.log("  trade fee (bps):         ", Number(await pm.tradeFeeBps()));
console.log("  position size (USDT):    ", usd(await pm.minPositionUsdt()), "to", usd(await pm.maxPositionUsdt()));
console.log("  total open cap (USDT):   ", usd(await pm.totalOpenCapUsdt()), "| open now:", usd(await pm.totalOpenUsdt()));
console.log("  user allowlist on:       ", await pm.userAllowlistEnabled());
console.log("  opening paused:          ", await pm.openingPaused());
console.log("  CAKE allowed:            ", await pm.tokenAllowed(cfg.tokens.CAKE));
console.log("  positions opened so far: ", Number(await pm.nextPositionId()));
console.log("  admin is the timelock:   ", await pm.hasRole(ethers.ZeroHash, cfg.governance.timelock));

console.log("\nGovernance");
console.log("  timelock", cfg.governance.timelock, "min delay (hours):", Number(await timelock.getMinDelay()) / 3600);
console.log("  Safe    ", cfg.governance.safe, `(${cfg.governance.safeThreshold})`);
