// KEYLESS premium-batch preparation: 16 curated names, owner = the Safe,
// 1 year, no resolver records (treasury custody). Computes commitments,
// register calldata, and ETH values; writes the plan (with commit secrets)
// to ~/.hawk-mainnet/premium-plan.json for the cast signing step.
import { createPublicClient, http, encodeFunctionData } from "viem";
import { writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  base,
  HAWK_ADDRESSES,
  makeRegistration,
  makeCommitment,
  randomSecret,
  hawkRegistrarControllerAbi,
} from "../dist/index.js";

// Names register TO the sale contract (it owns and sells them; the Safe
// owns the sale contract). Pass its address via PREMIUM_OWNER.
const OWNER = process.env.PREMIUM_OWNER;
if (!OWNER || OWNER.length !== 42) {
  console.error("set PREMIUM_OWNER to the deployed HawkPremiumSale address");
  process.exit(1);
}
// Labels via PREMIUM_LABELS (comma-separated); defaults to the wave-1 set.
const LABELS = process.env.PREMIUM_LABELS
  ? process.env.PREMIUM_LABELS.split(",").map((s) => s.trim()).filter(Boolean)
  : [
      "vitalik", "satoshi", "elon", "brian", "jesse", "hayden", "sergey",
      "anatoly", "saylor", "balaji", "naval", "stani", "cobie", "ansem",
      "gcr", "justin",
    ];

const A = HAWK_ADDRESSES[8453];
const pub = createPublicClient({ chain: base, transport: http() });
let total = 0n;
const items = [];
for (const label of LABELS) {
  if (!process.env.SKIP_AVAILABILITY) {
    const avail = await pub.readContract({
      address: A.controller, abi: hawkRegistrarControllerAbi,
      functionName: "available", args: [label],
    });
    if (!avail) { console.log(`SKIP ${label} — no longer available!`); continue; }
  }
  const reg = makeRegistration({
    label, owner: OWNER, duration: 31_536_000n, secret: randomSecret(),
  });
  const price = await pub.readContract({
    address: A.controller, abi: hawkRegistrarControllerAbi,
    functionName: "rentPrice", args: [label, 31_536_000n],
  });
  const value = ((price.base + price.premium) * 105n) / 100n;
  total += value;
  items.push({
    label,
    commitment: makeCommitment(reg),
    registerData: encodeFunctionData({
      abi: hawkRegistrarControllerAbi, functionName: "register", args: [reg],
    }),
    value: value.toString(),
  });
  console.log(`${label}: ${(Number(value) / 1e18).toFixed(5)} ETH`);
}
mkdirSync(join(homedir(), ".hawk-mainnet"), { recursive: true });
writeFileSync(
  join(homedir(), ".hawk-mainnet", "premium-plan.json"),
  JSON.stringify({ controller: A.controller, items }, null, 2),
);
console.log(`\n${items.length} names, total ≈ ${(Number(total) / 1e18).toFixed(4)} ETH (+gas)`);
console.log("PLAN_WRITTEN");
