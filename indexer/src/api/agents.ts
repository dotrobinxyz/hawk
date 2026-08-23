import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { and, desc, eq, inArray, isNotNull, like, ne } from "ponder";
import { namehash, normalize } from "viem/ens";

/**
 * Agent identity API — /verify/:name and /agents.
 *
 * Served entirely from the index (no RPC round-trips). A name "verifies" when
 * its node exists, its root .hawk registration is unexpired, and it has a
 * chain address record. A matching primary name (reverse record) is reported
 * as a stronger, optional signal — the address points back at the name.
 */

type Hex = `0x${string}`;

const ETH_COIN_TYPE = 60n;
const AGENT_KEY_PREFIX = "agent.";
const PROFILE_KEYS = ["url", "description", "avatar"];

const str = (v: bigint | null | undefined) => (v == null ? null : v.toString());

function parseHawkName(
  raw: string,
): { name: string; labels: string[] } | null {
  let n = decodeURIComponent(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/\.$/, "");
  if (n.length === 0) return null;
  if (!n.includes(".")) n = `${n}.hawk`;
  let name: string;
  try {
    name = normalize(n);
  } catch {
    return null;
  }
  const labels = name.split(".");
  if (labels.length < 2) return null;
  if (labels[labels.length - 1] !== "hawk") return null;
  if (labels.some((l) => l.length === 0)) return null;
  return { name, labels };
}

function splitCapabilities(value: string | null | undefined): string[] {
  if (!value) return [];
  return value
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

async function recordsAt(node: Hex) {
  const [texts, addrs] = await Promise.all([
    db.select().from(schema.textRecord).where(eq(schema.textRecord.node, node)),
    db
      .select()
      .from(schema.addressRecord)
      .where(
        and(
          eq(schema.addressRecord.node, node),
          eq(schema.addressRecord.coinType, ETH_COIN_TYPE),
        ),
      )
      .limit(1),
  ]);
  const records: Record<string, string> = {};
  for (const t of texts) if (t.value) records[t.key] = t.value;
  return { records, address: (addrs[0]?.value ?? null) as Hex | null };
}

export const agentApi = new Hono();

agentApi.get("/verify", (c) =>
  c.json({
    usage: "GET /verify/:name — verify a .hawk agent identity",
    example: "/verify/genesis.hawk",
  }),
);

agentApi.get("/verify/:name", async (c) => {
  const parsed = parseHawkName(c.req.param("name"));
  if (!parsed) {
    return c.json({ error: "not a valid .hawk name" }, 400);
  }
  const { name, labels } = parsed;
  const node = namehash(name) as Hex;
  const rootName = labels.slice(-2).join(".");
  const rootNode = namehash(rootName) as Hex;
  const now = BigInt(Math.floor(Date.now() / 1000));

  const [rootRows, subRows, { records, address }] = await Promise.all([
    db
      .select()
      .from(schema.name)
      .where(eq(schema.name.node, rootNode))
      .limit(1),
    labels.length > 2
      ? db
          .select()
          .from(schema.subname)
          .where(eq(schema.subname.id, node))
          .limit(1)
      : Promise.resolve([]),
    recordsAt(node),
  ]);
  const root = rootRows[0] ?? null;
  const sub = subRows[0] ?? null;

  // Records can only be set by the node's owner, so their presence proves the
  // node exists even when the subname was created outside the wrapper.
  const hasRecords = address != null || Object.keys(records).length > 0;
  const registered =
    labels.length === 2 ? root != null : sub != null || hasRecords;
  const rootActive = root != null && root.expiresAt > now;
  const owner = (labels.length === 2 ? root?.owner : sub?.owner) ?? null;

  let primary: string | null = null;
  if (address) {
    const p = await db
      .select()
      .from(schema.primaryName)
      .where(eq(schema.primaryName.address, address.toLowerCase() as Hex))
      .limit(1);
    primary = p[0]?.name ?? null;
  }

  // Ancestors between the name and the TLD: for a.b.c.hawk → b.c.hawk, c.hawk.
  const operatorChain = await Promise.all(
    labels.slice(1, -1).map(async (_, i) => {
      const ancestorName = labels.slice(i + 1).join(".");
      const ancestorNode = namehash(ancestorName) as Hex;
      const is2ld = labels.length - (i + 1) === 2;
      const [rows, anc] = await Promise.all([
        is2ld
          ? Promise.resolve([root].filter((r) => r != null))
          : db
              .select()
              .from(schema.subname)
              .where(eq(schema.subname.id, ancestorNode))
              .limit(1),
        recordsAt(ancestorNode),
      ]);
      return {
        name: ancestorName,
        node: ancestorNode,
        owner: (rows[0]?.owner ?? null) as Hex | null,
        address: anc.address,
      };
    }),
  );

  const checks = {
    registered,
    rootActive,
    addressSet: address != null,
    primaryMatch: address != null && primary === name,
  };

  c.header("cache-control", "public, max-age=30");
  return c.json({
    name,
    node,
    verified: checks.registered && checks.rootActive && checks.addressSet,
    checks,
    address,
    owner,
    primaryName: primary,
    root: root
      ? {
          name: rootName,
          node: rootNode,
          owner: root.owner,
          expiresAt: str(root.expiresAt),
          active: rootActive,
          wrapped: root.wrapped,
        }
      : null,
    operator: operatorChain[0] ?? null,
    operatorChain,
    records,
    agent: {
      capabilities: splitCapabilities(records[`${AGENT_KEY_PREFIX}capabilities`]),
      model: records[`${AGENT_KEY_PREFIX}model`] ?? null,
      operator: records[`${AGENT_KEY_PREFIX}operator`] ?? null,
      url: records["url"] ?? null,
      description: records["description"] ?? null,
      avatar: records["avatar"] ?? null,
    },
    asOf: str(now),
  });
});

/** Directory of every name that opted in by publishing an agent.* record. */
agentApi.get("/agents", async (c) => {
  const limitRaw = Number(c.req.query("limit") ?? "100");
  const limit = Math.min(
    Math.max(1, Number.isFinite(limitRaw) ? Math.floor(limitRaw) : 100),
    500,
  );
  const operatorFilter = c.req.query("operator")?.trim().toLowerCase() ?? null;
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
    .limit(2000);

  const byNode = new Map<
    Hex,
    { records: Record<string, string>; updatedAt: bigint }
  >();
  for (const r of agentRecords) {
    const node = r.node as Hex;
    const entry = byNode.get(node) ?? { records: {}, updatedAt: 0n };
    if (r.value) entry.records[r.key] = r.value;
    if (r.updatedAt > entry.updatedAt) entry.updatedAt = r.updatedAt;
    byNode.set(node, entry);
  }
  const nodes = [...byNode.keys()];
  if (nodes.length === 0) {
    c.header("cache-control", "public, max-age=30");
    return c.json({ agents: [], total: 0, asOf: str(now) });
  }

  const [names2ld, subs, addrs, profileTexts] = await Promise.all([
    db.select().from(schema.name).where(inArray(schema.name.node, nodes)),
    db.select().from(schema.subname).where(inArray(schema.subname.id, nodes)),
    db
      .select()
      .from(schema.addressRecord)
      .where(
        and(
          inArray(schema.addressRecord.node, nodes),
          eq(schema.addressRecord.coinType, ETH_COIN_TYPE),
        ),
      ),
    db
      .select()
      .from(schema.textRecord)
      .where(
        and(
          inArray(schema.textRecord.node, nodes),
          inArray(schema.textRecord.key, PROFILE_KEYS),
        ),
      ),
  ]);

  const nameByNode = new Map(names2ld.map((n) => [n.node as Hex, n]));
  const subByNode = new Map(subs.map((s) => [s.id as Hex, s]));
  const addrByNode = new Map(
    addrs.filter((a) => a.value).map((a) => [a.node as Hex, a.value as Hex]),
  );
  const profileByNode = new Map<Hex, Record<string, string>>();
  for (const t of profileTexts) {
    if (!t.value) continue;
    const p = profileByNode.get(t.node as Hex) ?? {};
    p[t.key] = t.value;
    profileByNode.set(t.node as Hex, p);
  }

  // Root registrations for subname entries, to report expiry/active state.
  const rootNodeByNode = new Map<Hex, Hex>();
  for (const s of subs) {
    const rootName = s.name.split(".").slice(-2).join(".");
    rootNodeByNode.set(s.id as Hex, namehash(rootName) as Hex);
  }
  const missingRoots = [...new Set(rootNodeByNode.values())].filter(
    (n) => !nameByNode.has(n),
  );
  if (missingRoots.length > 0) {
    const rootRows = await db
      .select()
      .from(schema.name)
      .where(inArray(schema.name.node, missingRoots));
    for (const r of rootRows) nameByNode.set(r.node as Hex, r);
  }

  const agents = [];
  for (const [node, entry] of byNode) {
    const two = nameByNode.get(node);
    const sub = subByNode.get(node);
    const fullName = two
      ? `${two.label ?? "?"}.hawk`
      : (sub?.name ?? null);
    if (!fullName) continue; // records on a node the index can't name
    const rootRow = two ?? nameByNode.get(rootNodeByNode.get(node)!);
    const operator = sub ? fullName.split(".").slice(1).join(".") : null;
    if (
      operatorFilter &&
      operator !== operatorFilter &&
      !`.${fullName}`.endsWith(`.${operatorFilter}`)
    )
      continue;
    const profile = profileByNode.get(node) ?? {};
    agents.push({
      name: fullName,
      node,
      address: addrByNode.get(node) ?? null,
      owner: (two?.owner ?? sub?.owner ?? null) as Hex | null,
      operator,
      capabilities: splitCapabilities(
        entry.records[`${AGENT_KEY_PREFIX}capabilities`],
      ),
      model: entry.records[`${AGENT_KEY_PREFIX}model`] ?? null,
      url: profile["url"] ?? null,
      description: profile["description"] ?? null,
      avatar: profile["avatar"] ?? null,
      active: rootRow != null && rootRow.expiresAt > now,
      expiresAt: str(rootRow?.expiresAt ?? null),
      updatedAt: str(entry.updatedAt),
    });
  }
  agents.sort((a, b) => Number(b.updatedAt ?? 0) - Number(a.updatedAt ?? 0));

  c.header("cache-control", "public, max-age=30");
  return c.json({
    agents: agents.slice(0, limit),
    total: agents.length,
    asOf: str(now),
  });
});
