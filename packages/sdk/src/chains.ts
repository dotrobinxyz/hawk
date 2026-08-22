import { defineChain, type Chain } from "viem";
import { HAWK_ADDRESSES, type HawkAddresses } from "./addresses.js";

const ZERO = "0x0000000000000000000000000000000000000000";

function ensContracts(addresses: HawkAddresses | undefined) {
  if (!addresses || addresses.registry === ZERO) return {};
  return {
    ensRegistry: { address: addresses.registry },
    ensUniversalResolver: { address: addresses.universalResolver },
  };
}

/**
 * Base mainnet (8453), with Hawk wired in as the chain's ENS —
 * `getEnsName`, `getEnsAddress`, `getEnsText`, `getEnsAvatar` and every
 * other viem/wagmi ENS action work out of the box against .hawk names.
 */
export const base: Chain = defineChain({
  id: 8453,
  name: "Base",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://mainnet.base.org"] },
  },
  blockExplorers: {
    default: {
      name: "Basescan",
      url: "https://basescan.org",
    },
  },
  contracts: {
    multicall3: {
      address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    },
    ...ensContracts(HAWK_ADDRESSES[8453]),
  },
});

/** Base Sepolia testnet (84532), Hawk wired in. */
export const baseSepolia: Chain = defineChain({
  id: 84532,
  name: "Base Sepolia",
  testnet: true,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://sepolia.base.org"] },
  },
  blockExplorers: {
    default: {
      name: "Basescan",
      url: "https://sepolia.basescan.org",
    },
  },
  contracts: {
    multicall3: {
      address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    },
    ...ensContracts(HAWK_ADDRESSES[84532]),
  },
});

/**
 * Wires Hawk resolution into any viem Chain object — the one-line
 * integration for dapps that already have their own chain config:
 *
 * ```ts
 * import { withHawk } from "hawk-names";
 * const chain = withHawk(myBaseChainConfig);
 * // viem's getEnsName / getEnsAddress now resolve .hawk
 * ```
 */
export function withHawk(
  chain: Chain,
  addresses?: HawkAddresses,
): Chain {
  const hawk = addresses ?? HAWK_ADDRESSES[chain.id];
  if (!hawk || hawk.registry === ZERO) {
    throw new Error(
      `No Hawk deployment known for chain ${chain.id} — pass addresses explicitly.`,
    );
  }
  return {
    ...chain,
    contracts: {
      ...chain.contracts,
      ensRegistry: { address: hawk.registry },
      ensUniversalResolver: { address: hawk.universalResolver },
    },
  };
}
