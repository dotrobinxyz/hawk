import type { Address } from "viem";

/** Every Hawk contract for one deployment. */
export type HawkAddresses = {
  registry: Address;
  baseRegistrar: Address;
  controller: Address;
  priceOracle: Address;
  wrapper: Address;
  metadata: Address;
  reservedList: Address;
  publicResolver: Address;
  reverseRegistrar: Address;
  defaultReverseRegistrar: Address;
  universalResolver: Address;
  usdc: Address;
};

const ZERO = "0x0000000000000000000000000000000000000000" as const;

/**
 * Canonical deployments by chain id.
 *
 * - 8453  — Base mainnet (populated at mainnet deploy)
 * - 84532 — Base Sepolia testnet (populated at testnet deploy)
 *
 * For a local/anvil deployment, build your own with `hawkAddressesFrom`
 * using the deploy script's deployments/hawk-local.json.
 */
export const HAWK_ADDRESSES: Record<number, HawkAddresses> = {
  8453: {
    registry: ZERO,
    baseRegistrar: ZERO,
    controller: ZERO,
    priceOracle: ZERO,
    wrapper: ZERO,
    metadata: ZERO,
    reservedList: ZERO,
    publicResolver: ZERO,
    reverseRegistrar: ZERO,
    defaultReverseRegistrar: ZERO,
    universalResolver: ZERO,
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  },
  84532: {
    registry: ZERO,
    baseRegistrar: ZERO,
    controller: ZERO,
    priceOracle: ZERO,
    wrapper: ZERO,
    metadata: ZERO,
    reservedList: ZERO,
    publicResolver: ZERO,
    reverseRegistrar: ZERO,
    defaultReverseRegistrar: ZERO,
    universalResolver: ZERO,
    usdc: ZERO,
  },
};

/** Maps a deployments/hawk-<network>.json record to HawkAddresses. */
export function hawkAddressesFrom(deployment: {
  HawkRegistry: Address;
  HawkBaseRegistrar: Address;
  HawkRegistrarController: Address;
  HawkPriceOracle: Address;
  HawkWrapper: Address;
  HawkMetadata: Address;
  HawkReservedList: Address;
  PublicResolver: Address;
  ReverseRegistrar: Address;
  DefaultReverseRegistrar: Address;
  UniversalResolver: Address;
  usdc: Address;
}): HawkAddresses {
  return {
    registry: deployment.HawkRegistry,
    baseRegistrar: deployment.HawkBaseRegistrar,
    controller: deployment.HawkRegistrarController,
    priceOracle: deployment.HawkPriceOracle,
    wrapper: deployment.HawkWrapper,
    metadata: deployment.HawkMetadata,
    reservedList: deployment.HawkReservedList,
    publicResolver: deployment.PublicResolver,
    reverseRegistrar: deployment.ReverseRegistrar,
    defaultReverseRegistrar: deployment.DefaultReverseRegistrar,
    universalResolver: deployment.UniversalResolver,
    usdc: deployment.usdc,
  };
}

export function getHawkAddresses(chainId: number): HawkAddresses {
  const addresses = HAWK_ADDRESSES[chainId];
  if (!addresses || addresses.registry === ZERO) {
    throw new Error(
      `Hawk is not deployed on chain ${chainId} in this SDK version — ` +
        `pass addresses explicitly (hawkAddressesFrom) or upgrade hawk-names.`,
    );
  }
  return addresses;
}
