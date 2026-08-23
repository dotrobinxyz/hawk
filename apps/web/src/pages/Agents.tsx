import { useState, type FormEvent, type ReactNode } from "react";
import { useLocation } from "wouter";
import { useQuery } from "@tanstack/react-query";
import { INDEXER_URL, EXPLORER } from "../config";
import { BandChip } from "../components/BandChip";
import { formatDate, shortAddress } from "../lib/format";

/**
 * Agent directory + verify — dark-launched behind AGENTS_ENABLED. All fetch
 * helpers live in this module so a flag-off build carries no trace of it.
 */

type VerifyResult = {
  name: string;
  node: `0x${string}`;
  verified: boolean;
  checks: {
    registered: boolean;
    rootActive: boolean;
    addressSet: boolean;
    primaryMatch: boolean;
  };
  address: `0x${string}` | null;
  owner: `0x${string}` | null;
  primaryName: string | null;
  root: {
    name: string;
    owner: `0x${string}`;
    expiresAt: string | null;
    active: boolean;
    wrapped: boolean;
  } | null;
  operatorChain: {
    name: string;
    owner: `0x${string}` | null;
    address: `0x${string}` | null;
  }[];
  records: Record<string, string>;
  agent: {
    capabilities: string[];
    model: string | null;
    operator: string | null;
    url: string | null;
    description: string | null;
    avatar: string | null;
  };
};

type AgentEntry = {
  name: string;
  node: `0x${string}`;
  address: `0x${string}` | null;
  owner: `0x${string}` | null;
  operator: string | null;
  capabilities: string[];
  model: string | null;
  url: string | null;
  description: string | null;
  active: boolean;
  expiresAt: string | null;
  updatedAt: string | null;
};

async function fetchVerify(name: string): Promise<VerifyResult> {
  const res = await fetch(`${INDEXER_URL}/verify/${encodeURIComponent(name)}`);
  if (res.status === 400) throw new Error("that is not a valid .hawk name.");
  if (!res.ok) throw new Error(`verify api ${res.status}`);
  return (await res.json()) as VerifyResult;
}

async function fetchDirectory(): Promise<AgentEntry[]> {
  const res = await fetch(`${INDEXER_URL}/agents?limit=200`);
  if (!res.ok) throw new Error(`agents api ${res.status}`);
  const body = (await res.json()) as { agents: AgentEntry[] };
  return body.agents;
}

function addressLink(address: `0x${string}`): ReactNode {
  const body = <span className="mono">{shortAddress(address)}</span>;
  return EXPLORER ? (
    <a href={`${EXPLORER}/address/${address}`} target="_blank" rel="noreferrer">
      {body}
    </a>
  ) : (
    body
  );
}

function CheckRow({
  ok,
  optional,
  label,
  detail,
}: {
  ok: boolean;
  optional?: boolean;
  label: string;
  detail?: ReactNode;
}) {
  const tag = ok ? (
    <span className="tag available">pass</span>
  ) : optional ? (
    <span className="tag gray">not set</span>
  ) : (
    <span className="tag danger">fail</span>
  );
  return (
    <div className="kv">
      <span className="muted">{label}</span>
      <span className="row" style={{ gap: 10 }}>
        {detail}
        {tag}
      </span>
    </div>
  );
}

function CapChips({ capabilities }: { capabilities: string[] }) {
  if (capabilities.length === 0) return null;
  return (
    <div className="row wrap" style={{ gap: 6 }}>
      {capabilities.map((cap) => (
        <span key={cap} className="tag gray">
          {cap}
        </span>
      ))}
    </div>
  );
}

function VerifyPanel({ name }: { name: string }) {
  const { data, error, isLoading } = useQuery({
    queryKey: ["verify", name],
    queryFn: () => fetchVerify(name),
    refetchInterval: 30_000,
  });

  if (isLoading) return <div className="empty">checking {name}…</div>;
  if (error)
    return <p className="form-error">{(error as Error).message}</p>;
  if (!data) return null;

  const { checks } = data;
  return (
    <div className="card stack" style={{ gap: 14 }}>
      <div className="row between wrap" style={{ gap: 10 }}>
        <BandChip name={data.name.replace(/\.hawk$/, "")} size="lg" />
        {data.verified ? (
          <span className="tag available">verified</span>
        ) : (
          <span className="tag danger">unverified</span>
        )}
      </div>

      <div>
        <CheckRow
          ok={checks.registered}
          label="name registered"
          detail={data.owner ? addressLink(data.owner) : undefined}
        />
        <CheckRow
          ok={checks.rootActive}
          label={`root ${data.root?.name ?? "—"} active`}
          detail={
            data.root?.expiresAt ? (
              <span className="muted small">
                until {formatDate(data.root.expiresAt)}
              </span>
            ) : undefined
          }
        />
        <CheckRow
          ok={checks.addressSet}
          label="resolves to an address"
          detail={data.address ? addressLink(data.address) : undefined}
        />
        <CheckRow
          ok={checks.primaryMatch}
          optional
          label="address points back (primary name)"
          detail={
            data.primaryName && !checks.primaryMatch ? (
              <span className="muted small">{data.primaryName}</span>
            ) : undefined
          }
        />
      </div>

      {data.operatorChain.length > 0 && (
        <div>
          <div className="muted small" style={{ marginBottom: 6 }}>
            answers to
          </div>
          <div className="row wrap" style={{ gap: 8 }}>
            {data.operatorChain.map((anc) => (
              <span key={anc.name} className="row" style={{ gap: 8 }}>
                <BandChip name={anc.name.replace(/\.hawk$/, "")} size="sm" />
                {anc.owner && (
                  <span className="muted small">{shortAddress(anc.owner)}</span>
                )}
              </span>
            ))}
          </div>
        </div>
      )}

      {(data.agent.capabilities.length > 0 ||
        data.agent.model ||
        data.agent.url ||
        data.agent.description) && (
        <div className="stack" style={{ gap: 8 }}>
          <div className="muted small">capability card</div>
          <CapChips capabilities={data.agent.capabilities} />
          {data.agent.description && <p>{data.agent.description}</p>}
          {data.agent.model && (
            <div className="kv">
              <span className="muted">model</span>
              <span className="mono">{data.agent.model}</span>
            </div>
          )}
          {data.agent.url && (
            <div className="kv">
              <span className="muted">endpoint</span>
              <a href={data.agent.url} target="_blank" rel="noreferrer">
                {data.agent.url}
              </a>
            </div>
          )}
        </div>
      )}

      <div className="muted small">
        machine-readable:{" "}
        <code>
          GET {INDEXER_URL}/verify/{data.name}
        </code>
      </div>
    </div>
  );
}

function DirectoryCard({ entry }: { entry: AgentEntry }) {
  const [, navigate] = useLocation();
  return (
    <button
      type="button"
      className="card stack agent-entry"
      style={{ gap: 10, textAlign: "left", cursor: "pointer" }}
      onClick={() => navigate(`/agents/${encodeURIComponent(entry.name)}`)}
    >
      <div className="row between wrap" style={{ gap: 8 }}>
        <BandChip name={entry.name.replace(/\.hawk$/, "")} size="sm" />
        {!entry.active && <span className="tag warn">expired</span>}
      </div>
      {entry.description && <p className="small">{entry.description}</p>}
      <CapChips capabilities={entry.capabilities} />
      <div className="stack" style={{ gap: 2 }}>
        {entry.operator && (
          <span className="muted small">operator {entry.operator}</span>
        )}
        {entry.address && (
          <span className="muted small mono">{shortAddress(entry.address)}</span>
        )}
      </div>
    </button>
  );
}

export function AgentsPage({ initial }: { initial?: string }) {
  const [, navigate] = useLocation();
  const target = (initial ?? "").trim().toLowerCase();
  const [query, setQuery] = useState(target);

  const { data: agents } = useQuery({
    queryKey: ["agents-directory"],
    queryFn: fetchDirectory,
    refetchInterval: 30_000,
  });

  function submit(event: FormEvent) {
    event.preventDefault();
    const raw = query.trim().toLowerCase().replace(/\.hawk$/, "");
    if (!raw) return;
    navigate(`/agents/${encodeURIComponent(`${raw}.hawk`)}`);
  }

  return (
    <>
      <section className="hero">
        <h1>The agent directory.</h1>
        <p>
          Every agent that publishes a capability card, in one place — and a
          verifier that walks any name back to its operator. Paste a
          counterparty&rsquo;s name and see who it answers to.
        </p>
        <form className="search" onSubmit={submit}>
          <input
            placeholder="verify any name — bot1.acme"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="search"
            aria-label="Verify a name"
          />
          {query.trim() !== "" && <span className="suffix">.hawk</span>}
          <button className="btn" type="submit">
            verify
          </button>
        </form>
      </section>

      {target !== "" && <VerifyPanel name={target} />}

      <h2 className="section-title">Live agents</h2>
      <p className="section-lede">
        Names that opted in by setting an <code>agent.*</code> text record.
        Set <code>agent.capabilities</code> on your name and your agent appears
        here.
      </p>
      {!agents || agents.length === 0 ? (
        <div className="empty">no agents published yet — be the first.</div>
      ) : (
        <div className="agent-grid">
          {agents.map((entry) => (
            <DirectoryCard key={entry.node} entry={entry} />
          ))}
        </div>
      )}
    </>
  );
}
