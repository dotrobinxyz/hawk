import { useMemo, useState } from "react";
import { useAccount } from "wagmi";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  encodeFunctionData,
  isAddress,
  type Address,
  type Hex,
} from "viem";
import {
  hawkWrapperAbi,
  publicResolverAbi,
  hawkNode,
  namehash,
  normalize,
} from "hawk-names";
import { ADDRESSES, CHAIN, EXPLORER } from "../config";
import { fetchNamesByOwner, fetchFleet, type IndexedSubname } from "../indexer";
import { useTx } from "../lib/useTx";
import { BandChip } from "../components/BandChip";
import { shortAddress } from "../lib/format";

/**
 * Fleet console — operator dashboard. Issue subnames in batch (owned by the
 * operator, so they stay revocable and the operator can write their records),
 * point each at its agent account, publish capability cards in one
 * transaction, and revoke a compromised agent with one click.
 */

const PARENT_CANNOT_CONTROL = 0x10000;
const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as Address;

type IssueRow = { label: string; addr: Address | null };

function parseRows(text: string): { rows: IssueRow[]; error: string | null } {
  const rows: IssueRow[] = [];
  const seen = new Set<string>();
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line === "") continue;
    const parts = line.split(/[\s,]+/).filter(Boolean);
    let label: string;
    try {
      label = normalize(parts[0]!);
      if (!label || label.includes(".")) throw new Error();
    } catch {
      return { rows, error: `"${parts[0]}" is not a valid label.` };
    }
    if (seen.has(label)) return { rows, error: `"${label}" appears twice.` };
    seen.add(label);
    let addr: Address | null = null;
    if (parts.length > 1) {
      if (!isAddress(parts[1]!)) {
        return { rows, error: `"${parts[1]}" is not a valid address.` };
      }
      addr = parts[1] as Address;
    }
    if (parts.length > 2) {
      return { rows, error: `too many values on line "${line}".` };
    }
    rows.push({ label, addr });
  }
  return { rows, error: null };
}

export function Fleet() {
  const { address, isConnected } = useAccount();

  const { data: owned } = useQuery({
    queryKey: ["names", address],
    queryFn: () => fetchNamesByOwner(address!),
    enabled: Boolean(address),
    refetchInterval: 30_000,
  });
  const wrapped = useMemo(
    () => (owned?.names ?? []).filter((n) => n.wrapped && n.label),
    [owned],
  );
  const unwrapped = useMemo(
    () => (owned?.names ?? []).filter((n) => !n.wrapped && n.label),
    [owned],
  );

  const [picked, setPicked] = useState<string | null>(null);
  const parentLabel = picked ?? wrapped[0]?.label ?? null;

  return (
    <>
      <section className="hero">
        <h1>Fleet console.</h1>
        <p>
          Run a fleet under one name: issue a subname per agent, point each at
          its account, publish capability cards in a single transaction, and
          revoke a compromised agent in one click.
        </p>
      </section>

      {!isConnected ? (
        <div className="empty">connect a wallet to manage your fleet.</div>
      ) : wrapped.length === 0 ? (
        <div className="card">
          <p>
            The console needs a <strong>wrapped</strong> name to issue subnames
            from.
          </p>
          {unwrapped.length > 0 ? (
            <p className="small muted">
              You own{" "}
              {unwrapped.map((n) => (
                <a key={n.id} href={`/name/${n.label}`} style={{ marginRight: 8 }}>
                  <BandChip name={n.label!} size="sm" />
                </a>
              ))}{" "}
              — open a name and wrap it (one click), then come back.
            </p>
          ) : (
            <p className="small muted">
              You don&rsquo;t own a .hawk name yet —{" "}
              <a href="/">register one</a>, wrap it, and your fleet lives under
              it.
            </p>
          )}
        </div>
      ) : (
        <>
          <div className="row wrap" style={{ gap: 8, margin: "6px 0 18px" }}>
            <span className="muted small">operator name:</span>
            {wrapped.map((n) => (
              <button
                key={n.id}
                type="button"
                style={{ background: "none", border: "none", padding: 0, cursor: "pointer" }}
                onClick={() => setPicked(n.label!)}
                aria-pressed={parentLabel === n.label}
              >
                <BandChip
                  name={n.label!}
                  size="sm"
                  variant={parentLabel === n.label ? "night" : "outline"}
                />
              </button>
            ))}
          </div>
          {parentLabel && (
            <FleetForParent key={parentLabel} parentLabel={parentLabel} operator={address as Address} />
          )}
        </>
      )}
    </>
  );
}

function FleetForParent({
  parentLabel,
  operator,
}: {
  parentLabel: string;
  operator: Address;
}) {
  const parentNode = useMemo(() => hawkNode(parentLabel), [parentLabel]);
  const queryClient = useQueryClient();
  const { data: fleet, refetch } = useQuery({
    queryKey: ["fleet", parentNode],
    queryFn: () => fetchFleet(parentNode),
    refetchInterval: 20_000,
  });
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const subnames = fleet?.subnames ?? [];
  const refresh = () => {
    // The indexer trails the chain by a block or two.
    setTimeout(() => {
      void refetch();
      void queryClient.invalidateQueries({ queryKey: ["fleet", parentNode] });
    }, 2500);
  };

  function toggle(node: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(node)) next.delete(node);
      else next.add(node);
      return next;
    });
  }

  return (
    <>
      <BatchIssue
        parentLabel={parentLabel}
        parentNode={parentNode}
        operator={operator}
        existing={new Set(subnames.map((s) => s.name.split(".")[0]!))}
        onDone={refresh}
      />

      <h2 className="section-title">
        Your fleet{subnames.length > 0 ? ` — ${subnames.length}` : ""}
      </h2>
      {subnames.length === 0 ? (
        <div className="empty">
          no subnames under {parentLabel}.hawk yet — issue your first batch
          above.
        </div>
      ) : (
        <>
          <div className="card" style={{ padding: 0 }}>
            {subnames.map((sub) => (
              <FleetRow
                key={sub.id}
                sub={sub}
                addr={fleet?.addrByNode[sub.id]}
                caps={fleet?.capsByNode[sub.id]}
                parentNode={parentNode}
                operator={operator}
                checked={selected.has(sub.id)}
                onToggle={() => toggle(sub.id)}
                onDone={refresh}
              />
            ))}
          </div>
          <BulkCard
            nodes={[...selected]}
            count={selected.size}
            onDone={() => {
              setSelected(new Set());
              refresh();
            }}
          />
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------

function BatchIssue({
  parentLabel,
  parentNode,
  operator,
  existing,
  onDone,
}: {
  parentLabel: string;
  parentNode: Hex;
  operator: Address;
  existing: Set<string>;
  onDone: () => void;
}) {
  const { walletClient, publicClient } = useTx();
  const [text, setText] = useState("");
  const [caps, setCaps] = useState("");
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const { rows, error: parseError } = useMemo(() => parseRows(text), [text]);
  const dupes = rows.filter((r) => existing.has(r.label));

  async function issue() {
    if (!walletClient || !publicClient || rows.length === 0) return;
    setError(null);
    try {
      // One transaction per subname: the wrapper mints to the operator with
      // the resolver pre-set, so records work immediately and the token
      // stays revocable.
      for (let i = 0; i < rows.length; i++) {
        setProgress(`issuing ${i + 1}/${rows.length} — ${rows[i]!.label}`);
        const hash = await walletClient.writeContract({
          address: ADDRESSES.wrapper,
          abi: hawkWrapperAbi,
          functionName: "setSubnodeRecord",
          args: [
            parentNode,
            rows[i]!.label,
            operator,
            ADDRESSES.publicResolver,
            0n,
            0,
            0n,
          ],
          chain: CHAIN,
          account: operator,
        });
        await publicClient.waitForTransactionReceipt({ hash });
      }

      // One more transaction for all the records: each agent's address plus
      // the shared capability card, batched through the resolver's multicall.
      const calls: Hex[] = [];
      const capsValue = caps.trim();
      for (const row of rows) {
        const node = namehash(`${row.label}.${parentLabel}.hawk`) as Hex;
        if (row.addr) {
          calls.push(
            encodeFunctionData({
              abi: publicResolverAbi,
              functionName: "setAddr",
              args: [node, row.addr],
            }),
          );
        }
        if (capsValue !== "") {
          calls.push(
            encodeFunctionData({
              abi: publicResolverAbi,
              functionName: "setText",
              args: [node, "agent.capabilities", capsValue],
            }),
          );
        }
      }
      if (calls.length > 0) {
        setProgress("writing records…");
        const hash = await walletClient.writeContract({
          address: ADDRESSES.publicResolver,
          abi: publicResolverAbi,
          functionName: "multicall",
          args: [calls],
          chain: CHAIN,
          account: operator,
        });
        await publicClient.waitForTransactionReceipt({ hash });
      }
      setText("");
      setCaps("");
      onDone();
    } catch (err) {
      const message =
        err instanceof Error
          ? ((err as { shortMessage?: string }).shortMessage ?? err.message)
          : String(err);
      setError(message);
    } finally {
      setProgress(null);
    }
  }

  return (
    <div className="card">
      <h3 style={{ margin: "0 0 4px" }}>Issue a batch</h3>
      <p className="small faint" style={{ margin: "0 0 12px" }}>
        One line per agent: <code>label</code> or{" "}
        <code>label 0xAgentAccount</code>. Subnames are minted to you (the
        operator) — revocable — and pointed at each agent&rsquo;s account.
      </p>
      <div className="field">
        <textarea
          className="input mono"
          rows={5}
          placeholder={`bot1 0x1234…\nbot2 0xabcd…\ntrader`}
          value={text}
          onChange={(e) => setText(e.target.value)}
          spellCheck={false}
          autoCapitalize="none"
          style={{ resize: "vertical", minHeight: 96 }}
        />
      </div>
      <div className="field">
        <label>shared capability card — agent.capabilities (optional)</label>
        <input
          className="input mono"
          placeholder="swap,quote,settlement"
          value={caps}
          onChange={(e) => setCaps(e.target.value)}
          autoCapitalize="none"
        />
      </div>
      {rows.length > 0 && !parseError && (
        <div className="row wrap" style={{ gap: 6, marginBottom: 12 }}>
          {rows.slice(0, 12).map((r) => (
            <BandChip key={r.label} name={`${r.label}.${parentLabel}`} size="sm" />
          ))}
          {rows.length > 12 && (
            <span className="muted small">+{rows.length - 12} more</span>
          )}
        </div>
      )}
      {parseError && <p className="notice danger small">{parseError}</p>}
      {dupes.length > 0 && (
        <p className="notice warn small">
          already issued: {dupes.map((d) => d.label).join(", ")} — remove them
          or the transactions will fail.
        </p>
      )}
      <button
        className="btn block"
        onClick={issue}
        disabled={
          progress !== null ||
          rows.length === 0 ||
          Boolean(parseError) ||
          dupes.length > 0
        }
      >
        {progress ? <span className="progress-ring" /> : null}
        {progress ??
          `issue ${rows.length === 0 ? "" : rows.length} subname${rows.length === 1 ? "" : "s"}`}
      </button>
      <p className="small faint" style={{ margin: "10px 0 0" }}>
        {rows.length > 1
          ? `${rows.length} wallet confirmations (one per subname), then one records transaction.`
          : "Each subname is one transaction; records land in one more."}
      </p>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------

function FleetRow({
  sub,
  addr,
  caps,
  parentNode,
  operator,
  checked,
  onToggle,
  onDone,
}: {
  sub: IndexedSubname;
  addr: `0x${string}` | undefined;
  caps: string | undefined;
  parentNode: Hex;
  operator: Address;
  checked: boolean;
  onToggle: () => void;
  onDone: () => void;
}) {
  const { run, busy, error, walletClient } = useTx();
  const label = sub.name.split(".")[0]!;
  const emancipated = (sub.fuses & PARENT_CANNOT_CONTROL) !== 0;
  const mine = sub.owner.toLowerCase() === operator.toLowerCase();

  async function revoke() {
    if (!walletClient) return;
    const clear: Hex[] = [
      encodeFunctionData({
        abi: publicResolverAbi,
        functionName: "setAddr",
        args: [sub.id, ZERO_ADDR],
      }),
      encodeFunctionData({
        abi: publicResolverAbi,
        functionName: "setText",
        args: [sub.id, "agent.capabilities", ""],
      }),
    ];
    await run(
      "revoke",
      [
        // Reclaim the token from whoever holds it, then clear its identity.
        async () =>
          mine
            ? null
            : walletClient.writeContract({
                address: ADDRESSES.wrapper,
                abi: hawkWrapperAbi,
                functionName: "setSubnodeOwner",
                args: [parentNode, label, operator, 0, 0n],
                chain: CHAIN,
                account: operator,
              }),
        async () =>
          walletClient.writeContract({
            address: ADDRESSES.publicResolver,
            abi: publicResolverAbi,
            functionName: "multicall",
            args: [clear],
            chain: CHAIN,
            account: operator,
          }),
      ],
      onDone,
    );
  }

  return (
    <div className="name-row" style={{ padding: "12px 18px" }}>
      <div className="row wrap" style={{ gap: 10, flex: 1, minWidth: 0 }}>
        <input
          type="checkbox"
          checked={checked}
          onChange={onToggle}
          aria-label={`select ${sub.name}`}
        />
        <a href={`/agents/${encodeURIComponent(sub.name)}`}>
          <BandChip name={sub.name.replace(/\.hawk$/, "")} size="sm" />
        </a>
        <span className="muted small mono">
          {addr ? (
            EXPLORER ? (
              <a href={`${EXPLORER}/address/${addr}`} target="_blank" rel="noreferrer">
                {shortAddress(addr)}
              </a>
            ) : (
              shortAddress(addr)
            )
          ) : (
            "no address"
          )}
        </span>
        {caps && <span className="tag gray">{caps}</span>}
        {emancipated && <span className="tag warn">emancipated</span>}
        {!mine && !emancipated && <span className="tag gray">held by agent</span>}
      </div>
      <div className="row" style={{ gap: 8 }}>
        <button
          className="btn danger small"
          onClick={revoke}
          disabled={busy !== null || emancipated}
          title={
            emancipated
              ? "emancipated — the parent gave up control"
              : "reclaim the subname and clear its identity"
          }
        >
          {busy ? <span className="progress-ring" /> : null} revoke
        </button>
      </div>
      {error && <p className="notice danger small" style={{ margin: "8px 0 0" }}>{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------

function BulkCard({
  nodes,
  count,
  onDone,
}: {
  nodes: string[];
  count: number;
  onDone: () => void;
}) {
  const { run, busy, error, walletClient } = useTx();
  const { address } = useAccount();
  const [caps, setCaps] = useState("");
  const [model, setModel] = useState("");
  const [url, setUrl] = useState("");

  const fields: [string, string][] = [
    ["agent.capabilities", caps],
    ["agent.model", model],
    ["url", url],
  ];
  const active = fields.filter(([, v]) => v.trim() !== "");

  async function apply() {
    if (!walletClient || !address || nodes.length === 0 || active.length === 0)
      return;
    const calls: Hex[] = [];
    for (const node of nodes) {
      for (const [key, value] of active) {
        calls.push(
          encodeFunctionData({
            abi: publicResolverAbi,
            functionName: "setText",
            args: [node as Hex, key, value.trim()],
          }),
        );
      }
    }
    await run(
      "bulk-card",
      [
        async () =>
          walletClient.writeContract({
            address: ADDRESSES.publicResolver,
            abi: publicResolverAbi,
            functionName: "multicall",
            args: [calls],
            chain: CHAIN,
            account: address,
          }),
      ],
      () => {
        setCaps("");
        setModel("");
        setUrl("");
        onDone();
      },
    );
  }

  return (
    <div className="card">
      <h3 style={{ margin: "0 0 4px" }}>
        Bulk capability card{count > 0 ? ` — ${count} selected` : ""}
      </h3>
      <p className="small faint" style={{ margin: "0 0 12px" }}>
        Select agents above, fill any of the fields, and every record lands in
        a single transaction. Filled fields overwrite; empty fields are left
        untouched.
      </p>
      <div className="field">
        <label>agent.capabilities</label>
        <input
          className="input mono"
          placeholder="swap,quote,settlement"
          value={caps}
          onChange={(e) => setCaps(e.target.value)}
          autoCapitalize="none"
        />
      </div>
      <div className="field">
        <label>agent.model</label>
        <input
          className="input mono"
          placeholder="claude-sonnet-5"
          value={model}
          onChange={(e) => setModel(e.target.value)}
          autoCapitalize="none"
        />
      </div>
      <div className="field">
        <label>url</label>
        <input
          className="input mono"
          placeholder="https://agents.example.com"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          autoCapitalize="none"
        />
      </div>
      <button
        className="btn block"
        onClick={apply}
        disabled={busy !== null || count === 0 || active.length === 0}
      >
        {busy ? <span className="progress-ring" /> : null}
        apply to {count} agent{count === 1 ? "" : "s"} — one transaction
      </button>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}
