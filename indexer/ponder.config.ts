import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createConfig } from "ponder";

import {
  publicResolverAbi,
  reverseRegistrarAbi,
  hawkBaseRegistrarAbi,
  hawkRegistrarControllerAbi,
  hawkRegistryAbi,
  hawkReservedListAbi,
  hawkWrapperAbi,
  hawkBondAbi,
} from "./abis/hawk";

// Network selection: HAWK_NETWORK ∈ local | base-sepolia | base.
// Addresses come straight from the deploy script's record, so the indexer
// can never drift from what's on chain.
const network = process.env.HAWK_NETWORK ?? "local";

const CHAINS: Record<string, { id: number; rpc: string | string[] }> = {
  local: { id: 31337, rpc: process.env.RPC_URL ?? "http://127.0.0.1:8545" },
  "base-sepolia": {
    id: 84532,
    // sepolia.base.org has had health blips — give ponder fallbacks.
    rpc: process.env.RPC_URL
      ? [process.env.RPC_URL]
      : [
          "https://base-sepolia-rpc.publicnode.com",
          "https://base-sepolia.drpc.org",
          "https://sepolia.base.org",
        ],
  },
  base: {
    id: 8453,
    rpc: process.env.RPC_URL
      ? [process.env.RPC_URL]
      : [
          "https://base-rpc.publicnode.com",
          "https://base.drpc.org",
          "https://mainnet.base.org",
        ],
  },
};

const chainInfo = CHAINS[network];
if (!chainInfo) throw new Error(`unknown HAWK_NETWORK: ${network}`);

const deployment = JSON.parse(
  readFileSync(
    process.env.DEPLOYMENT_FILE ??
      join(__dirname, `../contracts/deployments/hawk-${network}.json`),
    "utf8",
  ),
) as Record<string, string>;

const startBlock = Number(process.env.START_BLOCK ?? 0);

export default createConfig({
  // In production set DATABASE_URL (Postgres). For dev, PGlite — kept off
  // Windows-mounted paths (WSL drvfs I/O stalls it); override with PGLITE_DIR.
  database: process.env.DATABASE_URL
    ? { kind: "postgres", connectionString: process.env.DATABASE_URL }
    : {
        kind: "pglite",
        directory:
          process.env.PGLITE_DIR ??
          join(
            process.env.HOME ?? ".",
            ".hawk-indexer",
            `pglite-${network}`,
          ),
      },
  chains: {
    base: { id: chainInfo.id, rpc: chainInfo.rpc },
  },
  contracts: {
    HawkRegistrarController: {
      chain: "base",
      abi: hawkRegistrarControllerAbi,
      address: deployment.HawkRegistrarController as `0x${string}`,
      startBlock,
    },
    HawkBaseRegistrar: {
      chain: "base",
      abi: hawkBaseRegistrarAbi,
      address: deployment.HawkBaseRegistrar as `0x${string}`,
      startBlock,
    },
    HawkWrapper: {
      chain: "base",
      abi: hawkWrapperAbi,
      address: deployment.HawkWrapper as `0x${string}`,
      startBlock,
    },
    HawkRegistry: {
      chain: "base",
      abi: hawkRegistryAbi,
      address: deployment.HawkRegistry as `0x${string}`,
      startBlock,
    },
    HawkReservedList: {
      chain: "base",
      abi: hawkReservedListAbi,
      address: deployment.HawkReservedList as `0x${string}`,
      startBlock,
    },
    PublicResolver: {
      chain: "base",
      abi: publicResolverAbi,
      address: deployment.PublicResolver as `0x${string}`,
      startBlock,
    },
    ReverseRegistrar: {
      chain: "base",
      abi: reverseRegistrarAbi,
      address: deployment.ReverseRegistrar as `0x${string}`,
      startBlock,
    },
    HawkBond: {
      chain: "base",
      abi: hawkBondAbi,
      address: "0xE7d326fB486aCC1ae90559fBCe9863503C9DbC83",
      startBlock: network === "base" ? 50_699_178 : 2_000_000_000,
    },
  },
});
