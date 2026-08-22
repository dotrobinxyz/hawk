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
    registry: "0x5DAF4DF48b022Bf0Fb454DBe9CB2592d3A32b0b2",
    baseRegistrar: "0x83dcABD50E531325C76b9CB07F4C04Aca187722E",
    controller: "0x65Acb254B2EF5af1FDFf7B8C77427Ca051Ff4F71",
    priceOracle: "0x697b2C75652b6895D507b9C8E2Cb3b3C8EfccA29",
    wrapper: "0x0B922e8B56c778667AbDbBBa522880F98362c6C8",
    metadata: "0xA972f32580C2DD8eEf379e27B4B91b205BF3437F",
    reservedList: "0x351c51AA3079e7f7EbeFb5079A92279b22a0AB6c",
    publicResolver: "0xC7cAB8Af20fF52346F4e93c143Cc8e9d6384e26b",
    reverseRegistrar: "0x4221F2953294ec98Ddf54964DB293E281db71daB",
    defaultReverseRegistrar: "0x34acC481E26Ee9566d868F455BecD05353Bae257",
    universalResolver: "0x1Ebbe68AfA011ADBE561De6215B1AA1Fe0e4bc6C",
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
