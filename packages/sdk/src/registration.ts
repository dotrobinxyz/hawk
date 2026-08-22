import {
  encodeAbiParameters,
  keccak256,
  toHex,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from "viem";
import { namehash, normalize } from "viem/ens";

/** namehash('hawk') */
export const HAWK_NODE =
  "0xf431efc1fb1b854a38191ac67de7e1ee70205b40f71cb927c938685e82e05403" as const;

/** Reverse-record bits for Registration.reverseRecord. */
export const REVERSE_RECORD_NONE = 0;
export const REVERSE_RECORD_CHAIN = 1; // addr.reverse on Base
export const REVERSE_RECORD_DEFAULT = 2; // default.reverse (EVM-wide fallback)

/** Mirror of HawkRegistrarController's Registration struct. */
export type Registration = {
  label: string;
  owner: Address;
  duration: bigint;
  secret: Hex;
  resolver: Address;
  data: readonly Hex[];
  reverseRecord: number;
  referrer: Hex;
};

export function makeRegistration(params: {
  label: string;
  owner: Address;
  duration: bigint;
  secret: Hex;
  resolver?: Address;
  data?: readonly Hex[];
  reverseRecord?: number;
  referrer?: Hex;
}): Registration {
  return {
    label: params.label,
    owner: params.owner,
    duration: params.duration,
    secret: params.secret,
    resolver: params.resolver ?? zeroAddress,
    data: params.data ?? [],
    reverseRecord: params.reverseRecord ?? REVERSE_RECORD_NONE,
    referrer: params.referrer ?? zeroHash,
  };
}

const REGISTRATION_TUPLE = {
  type: "tuple",
  components: [
    { name: "label", type: "string" },
    { name: "owner", type: "address" },
    { name: "duration", type: "uint256" },
    { name: "secret", type: "bytes32" },
    { name: "resolver", type: "address" },
    { name: "data", type: "bytes[]" },
    { name: "reverseRecord", type: "uint8" },
    { name: "referrer", type: "bytes32" },
  ],
} as const;

/**
 * Computes the commit-reveal commitment for a registration —
 * `keccak256(abi.encode(registration))`, byte-identical to the
 * controller's `makeCommitment`.
 */
export function makeCommitment(registration: Registration): Hex {
  return keccak256(
    encodeAbiParameters([REGISTRATION_TUPLE], [registration]),
  );
}

/** Random 32-byte commit-reveal secret (browser + node). */
export function randomSecret(): Hex {
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return toHex(bytes);
}

/** The namehash of `<label>.hawk`. */
export function hawkNode(label: string): Hex {
  return namehash(`${normalize(label)}.hawk`);
}

/** The ERC-721 token id (labelhash) for a .hawk second-level name. */
export function hawkTokenId(label: string): bigint {
  return BigInt(keccak256(toHex(normalize(label))));
}

/**
 * Client-side registrability check, mirroring the controller's `valid` plus
 * ENSIP-15 normalization (the on-chain check is length-only; apps must
 * normalize). Returns the normalized label or throws with the reason.
 */
export function validateLabel(rawLabel: string): string {
  const label = normalize(rawLabel);
  if (label.includes(".")) {
    throw new Error("A label cannot contain dots.");
  }
  if ([...label].length < 3) {
    throw new Error("Names must be at least 3 characters.");
  }
  return label;
}

export const SECONDS_PER_YEAR = 31_536_000n; // 365 days, the pricing year
export const MIN_REGISTRATION_DURATION_MAINNET = 2_419_200n; // 28 days
export const MAX_REGISTRATION_DURATION = 315_360_000n; // 3650 days
