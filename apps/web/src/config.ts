import { http, createConfig } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { defineChain, type Chain } from "viem";
import {
  hawkAddressesFrom,
  withHawk,
  type HawkAddresses,
} from "hawk-names";
import { DEPLOYMENTS } from "./generated/deployments";

export type NetworkKey = "local" | "base-sepolia" | "base";

export const NETWORK = (import.meta.env.VITE_HAWK_NETWORK ??
  "local") as NetworkKey;

const deployment = (DEPLOYMENTS as Record<string, unknown>)[NETWORK] as
  | Parameters<typeof hawkAddressesFrom>[0]
  | undefined;
if (!deployment) {
  throw new Error(
    `No deployment record for network "${NETWORK}" — run the deploy and apps/web/scripts/sync-addresses.mjs`,
  );
}

export const ADDRESSES: HawkAddresses = hawkAddressesFrom(deployment);

const BASE_CHAINS: Record<NetworkKey, Chain> = {
  local: defineChain({
    id: 31337,
    name: "Anvil",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
  }),
  "base-sepolia": defineChain({
    id: 84532,
    name: "Base Testnet",
    testnet: true,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: {
      default: { http: ["https://sepolia.base.org"] },
    },
    blockExplorers: {
      default: {
        name: "Blockscout",
        url: "https://sepolia.basescan.org",
      },
    },
    contracts: {
      multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
    },
  }),
  base: defineChain({
    id: 8453,
    name: "Base",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: {
      default: { http: ["https://mainnet.base.org"] },
    },
    blockExplorers: {
      default: {
        name: "Blockscout",
        url: "https://basescan.org",
      },
    },
    contracts: {
      multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
    },
  }),
};

/** The active chain, with Hawk wired in as its ENS. */
export const CHAIN = withHawk(BASE_CHAINS[NETWORK], ADDRESSES);

export const EXPLORER = CHAIN.blockExplorers?.default.url;

export const INDEXER_URL =
  import.meta.env.VITE_INDEXER_URL ?? "http://localhost:42069";

/**
 * Dark-launch flag for the agent directory + verify UI. Absent from the
 * build env, this folds to a constant false and the whole feature is
 * tree-shaken out of the bundle.
 */
export const AGENTS_ENABLED = import.meta.env.VITE_HAWK_AGENTS === "1";

/** Premium auction length per network (oracle constructor parameter). */
export const PREMIUM_DAYS = NETWORK === "base-sepolia" ? 2 : 21;

const wcProjectId = import.meta.env.VITE_WC_PROJECT_ID as string | undefined;

export const wagmiConfig = createConfig({
  chains: [CHAIN],
  connectors: [
    injected(),
    ...(wcProjectId ? [walletConnect({ projectId: wcProjectId })] : []),
  ],
  transports: { [CHAIN.id]: http() },
});
