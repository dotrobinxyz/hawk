// hawk-names — resolve and register .hawk names on Base.
//
// One-line dapp integration:
//   import { createPublicClient, http } from "viem";
//   import { base } from "hawk-names";
//   const client = createPublicClient({ chain: base, transport: http() });
//   await client.getEnsName({ address: "0x..." });   // → "trader.hawk"

export {
  base,
  baseSepolia,
  withHawk,
} from "./chains.js";

export {
  HAWK_ADDRESSES,
  getHawkAddresses,
  hawkAddressesFrom,
  type HawkAddresses,
} from "./addresses.js";

export {
  getHawkName,
  getHawkAddress,
  getHawkText,
  getHawkAvatar,
} from "./actions.js";

export {
  HAWK_NODE,
  REVERSE_RECORD_NONE,
  REVERSE_RECORD_CHAIN,
  REVERSE_RECORD_DEFAULT,
  SECONDS_PER_YEAR,
  MIN_REGISTRATION_DURATION_MAINNET,
  MAX_REGISTRATION_DURATION,
  type Registration,
  makeRegistration,
  makeCommitment,
  randomSecret,
  hawkNode,
  hawkTokenId,
  validateLabel,
} from "./registration.js";

export { normalize, namehash, labelhash } from "viem/ens";

export * from "./generated/abis.js";
