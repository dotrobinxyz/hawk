import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { and, desc, inArray, isNotNull, like, ne } from "ponder";
import { paymentMiddleware, x402ResourceServer } from "@x402/hono";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { HTTPFacilitatorClient } from "@x402/core/server";
import { facilitator as cdpFacilitator } from "@coinbase/x402";

/**
 * Premium endpoints, sold over x402 — hawk earning through the same rail
 * it secures. The free API stays free (/verify, /agents); the bulk
 * directory export costs a few cents per request, settled in USDC on
 * Base to the treasury Safe.
 *
 * Facilitator: with CDP_API_KEY_ID/SECRET in the environment the Coinbase
 * facilitator config is used (Base mainnet settlement); otherwise
 * HAWK_X402_FACILITATOR_URL (default x402.org). Mounted only when
 * HAWK_X402=1, same dark-launch pattern as the agent API.
 */

type Hex = `0x${string}`;

const PAY_TO = (process.env.HAWK_X402_PAYTO ??
  "0xd0eC82124401A30d8337FEF77899e883bb12Df0b") as Hex; // hawk treasury Safe
const NETWORK = "eip155:8453"; // Base mainnet
const PRICE = process.env.HAWK_X402_PRICE ?? "$0.05";
const AGENT_KEY_PREFIX = "agent.";
const ETH_COIN_TYPE = 60n;

const str = (v: bigint | null | undefined) => (v == null ? null : v.toString());

function facilitatorClient(): HTTPFacilitatorClient {
  if (process.env.CDP_API_KEY_ID && process.env.CDP_API_KEY_SECRET) {
    return new HTTPFacilitatorClient(cdpFacilitator);
  }
  return new HTTPFacilitatorClient({
    url: process.env.HAWK_X402_FACILITATOR_URL ?? "https://x402.org/facilitator",
  });
}

export const paidApi = new Hono();

const resourceServer = new x402ResourceServer(facilitatorClient()).register(
  NETWORK,
  new ExactEvmScheme(),
);

paidApi.use(
  paymentMiddleware(
    {
      "GET /directory/export": {
        accepts: {
          scheme: "exact",
          price: PRICE,
          network: NETWORK,
          payTo: PAY_TO,
        },
        description:
          "Full hawk agent directory export: every agent identity with its records, addresses and owners.",
      },
    },
    resourceServer,
    undefined,
    undefined,
    // Never let facilitator availability decide whether the indexer boots.
    false,
  ),
);

/** The whole directory in one response — every node carrying agent.*
 *  records, with owners, addresses, and full record sets. */
paidApi.get("/directory/export", async (c) => {
  const now = BigInt(Math.floor(Date.now() / 1000));

  const agentRecords = await db
    .select()
    .from(schema.textRecord)
    .where(
      and(
        like(schema.textRecord.key, `${AGENT_KEY_PREFIX}%`),
        isNotNull(schema.textRecord.value),
        ne(schema.textRecord.value, ""),
      ),
    )
    .orderBy(desc(schema.textRecord.updatedAt))
    .limit(10_000);

  const byNode = new Map<Hex, { records: Record<string, string>; updatedAt: bigint }>();
  for (const r of agentRecords) {
    const node = r.node as Hex;
    const entry = byNode.get(node) ?? { records: {}, updatedAt: 0n };
    if (r.value) entry.records[r.key] = r.value;
    if (r.updatedAt > entry.updatedAt) entry.updatedAt = r.updatedAt;
    byNode.set(node, entry);
  }
  const nodes = [...byNode.keys()];
  if (nodes.length === 0) {
    return c.json({ agents: [], total: 0, asOf: str(now) });
  }

  const [names2ld, subs, addrs, allTexts] = await Promise.all([
    db.select().from(schema.name).where(inArray(schema.name.node, nodes)),
    db.select().from(schema.subname).where(inArray(schema.subname.id, nodes)),
    db
      .select()
      .from(schema.addressRecord)
      .where(inArray(schema.addressRecord.node, nodes)),
    db
      .select()
      .from(schema.textRecord)
      .where(inArray(schema.textRecord.node, nodes)),
  ]);

  const nameByNode = new Map(names2ld.map((n) => [n.node as Hex, n]));
  const subByNode = new Map(subs.map((s) => [s.id as Hex, s]));
  const addrByNode = new Map<Hex, string>();
  for (const a of addrs) {
    if (a.coinType === ETH_COIN_TYPE && a.value) addrByNode.set(a.node as Hex, a.value);
  }
  const textsByNode = new Map<Hex, Record<string, string>>();
  for (const t of allTexts) {
    if (!t.value) continue;
    const m = textsByNode.get(t.node as Hex) ?? {};
    m[t.key] = t.value;
    textsByNode.set(t.node as Hex, m);
  }

  const agents = nodes.map((node) => {
    const two = nameByNode.get(node);
    const sub = subByNode.get(node);
    const name = two?.label ? `${two.label}.hawk` : (sub?.name ?? null);
    return {
      node,
      name,
      kind: two ? "name" : sub ? "subname" : "unknown",
      owner: (two?.owner ?? sub?.owner ?? null) as Hex | null,
      address: (addrByNode.get(node) ?? null) as Hex | null,
      expiresAt: str(two?.expiresAt ?? null),
      records: textsByNode.get(node) ?? byNode.get(node)!.records,
      updatedAt: str(byNode.get(node)!.updatedAt),
    };
  });

  return c.json({ agents, total: agents.length, asOf: str(now) });
});
