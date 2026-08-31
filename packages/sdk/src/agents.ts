/**
 * Agent trust for the x402 economy: resolve a .hawk name, check the four
 * HIP-1 verification proofs, and only then let money move.
 *
 * The x402 client itself stays out of this package — pass any
 * payment-capable fetch (for example `@x402/fetch`'s wrapped fetch) and
 * this module gates it behind verification. Zero new dependencies.
 */

const DEFAULT_API = "https://api.dothawk.xyz";

export type AgentChecks = {
  registered: boolean;
  rootActive: boolean;
  addressSet: boolean;
  primaryMatch: boolean;
};

export type AgentInfo = {
  name: string;
  node: `0x${string}`;
  verified: boolean;
  checks: AgentChecks;
  address: `0x${string}` | null;
  primaryName: string | null;
  capabilities: string[];
  url: string | null;
  records: Record<string, string>;
  operator: { name: string; address: `0x${string}` | null } | null;
};

export class AgentNotVerifiedError extends Error {
  readonly agent: AgentInfo;

  constructor(agent: AgentInfo) {
    const failed = Object.entries(agent.checks)
      .filter(([, ok]) => !ok)
      .map(([k]) => k)
      .join(", ");
    super(
      `${agent.name} is not a verified agent (failing: ${failed || "unknown"})`,
    );
    this.name = "AgentNotVerifiedError";
    this.agent = agent;
  }
}

/** Fetch an agent's verification report from the hawk verify API. */
export async function resolveAgent(
  name: string,
  opts: { apiUrl?: string; fetch?: typeof fetch } = {},
): Promise<AgentInfo> {
  const api = (opts.apiUrl ?? DEFAULT_API).replace(/\/$/, "");
  const f = opts.fetch ?? fetch;
  const res = await f(`${api}/verify/${encodeURIComponent(name)}`);
  if (!res.ok) {
    throw new Error(`hawk verify API: HTTP ${res.status} for ${name}`);
  }
  const body = (await res.json()) as {
    name: string;
    node: `0x${string}`;
    verified: boolean;
    checks: AgentChecks;
    address: `0x${string}` | null;
    primaryName: string | null;
    records: Record<string, string>;
    agent: { capabilities: string[]; url: string | null };
    operator: { name: string; address: `0x${string}` | null } | null;
  };
  return {
    name: body.name,
    node: body.node,
    verified: body.verified,
    checks: body.checks,
    address: body.address,
    primaryName: body.primaryName,
    capabilities: body.agent?.capabilities ?? [],
    url: body.agent?.url ?? null,
    records: body.records ?? {},
    operator: body.operator
      ? { name: body.operator.name, address: body.operator.address }
      : null,
  };
}

/** Resolve an agent and throw unless all four verification checks pass. */
export async function requireVerifiedAgent(
  name: string,
  opts: { apiUrl?: string; fetch?: typeof fetch } = {},
): Promise<AgentInfo> {
  const agent = await resolveAgent(name, opts);
  if (!agent.verified) throw new AgentNotVerifiedError(agent);
  return agent;
}

export type VerifiedFetch = (
  agentName: string,
  path?: string,
  init?: RequestInit,
) => Promise<Response>;

/**
 * Gate a payment-capable fetch behind hawk verification.
 *
 * `payFetch` is any fetch-shaped function — typically the result of
 * `@x402/fetch`'s `wrapFetchWithPaymentFromConfig(fetch, …)`, so 402
 * challenges from the agent's endpoint are paid automatically, but ONLY
 * after the agent proved who it is:
 *
 * ```ts
 * import { wrapFetchWithPaymentFromConfig } from "@x402/fetch";
 * import { ExactEvmScheme } from "@x402/evm";
 * import { verifiedFetch } from "hawk-names/agents";
 *
 * const pay = wrapFetchWithPaymentFromConfig(fetch, {
 *   schemes: [{ network: "eip155:8453", client: new ExactEvmScheme(account) }],
 * });
 * const callAgent = verifiedFetch(pay);
 * const res = await callAgent("quotes.acme.hawk", "/price?pair=ETH-USDC");
 * ```
 *
 * The agent's base URL comes from its on-chain `url` record; `path` is
 * appended. Refuses to call agents whose verification fails.
 */
export function verifiedFetch(
  payFetch: typeof fetch,
  opts: { apiUrl?: string } = {},
): VerifiedFetch {
  return async (agentName, path = "", init) => {
    const agent = await requireVerifiedAgent(agentName, opts);
    if (!agent.url) {
      throw new Error(
        `${agent.name} is verified but publishes no url record to call`,
      );
    }
    const base = agent.url.replace(/\/$/, "");
    const target = path ? `${base}${path.startsWith("/") ? "" : "/"}${path}` : base;
    return payFetch(target, init);
  };
}

/**
 * The address money should go to for a named agent — verified first.
 * Use this when constructing payments yourself (x402 payTo, transfers).
 */
export async function verifiedPayTo(
  name: string,
  opts: { apiUrl?: string; fetch?: typeof fetch } = {},
): Promise<`0x${string}`> {
  const agent = await requireVerifiedAgent(name, opts);
  if (!agent.address) {
    throw new Error(`${agent.name} has no address record`);
  }
  return agent.address;
}
