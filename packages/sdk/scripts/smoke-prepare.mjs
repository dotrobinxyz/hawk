// KEYLESS smoke preparation: computes the commitment hash, register calldata,
// and ETH value for goldfinch.hawk. Touches no private key — signing happens
// separately via cast. Writes JSON for the cast step and prints it.
import { createPublicClient, http, encodeFunctionData } from "viem";
import { writeFileSync } from "node:fs";
import {
  base,
  HAWK_ADDRESSES,
  makeRegistration,
  makeCommitment,
  randomSecret,
  hawkNode,
  REVERSE_RECORD_CHAIN,
  hawkRegistrarControllerAbi,
  publicResolverAbi,
} from "../dist/index.js";

const A = HAWK_ADDRESSES[8453];
const OWNER = "0x18A3675e49ec7F2782aC0A2515451d60A7645301"; // deployer (public)
const LABEL = "goldfinch";
const node = hawkNode(LABEL);
const pub = createPublicClient({ chain: base, transport: http() });

const reg = makeRegistration({
  label: LABEL,
  owner: OWNER,
  duration: 31_536_000n,
  secret: randomSecret(),
  resolver: A.publicResolver,
  data: [
    encodeFunctionData({ abi: publicResolverAbi, functionName: "setAddr", args: [node, OWNER] }),
    encodeFunctionData({ abi: publicResolverAbi, functionName: "setText", args: [node, "url", "https://dothawk.xyz"] }),
  ],
  reverseRecord: REVERSE_RECORD_CHAIN,
});
const commitment = makeCommitment(reg);
const registerData = encodeFunctionData({ abi: hawkRegistrarControllerAbi, functionName: "register", args: [reg] });
const price = await pub.readContract({ address: A.controller, abi: hawkRegistrarControllerAbi, functionName: "rentPrice", args: [LABEL, 31_536_000n] });
const value = (((price.base ?? price[0]) + (price.premium ?? price[1])) * 105n) / 100n;

const out = {
  controller: A.controller,
  baseRegistrar: A.baseRegistrar,
  wrapper: A.wrapper,
  publicResolver: A.publicResolver,
  commitment,
  registerData,
  value: value.toString(),
  node,
};
writeFileSync(new URL("./smoke-plan.json", import.meta.url), JSON.stringify(out, null, 2));
console.log(JSON.stringify({ commitment, value: out.value, registerDataBytes: registerData.length / 2 - 1 }, null, 2));
console.log("PLAN_WRITTEN");
