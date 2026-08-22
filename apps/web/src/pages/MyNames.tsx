import { useAccount } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { Link } from "wouter";
import { fetchNamesByOwner } from "../indexer";
import { formatDate } from "../lib/format";
import { BandChip } from "../components/BandChip";

export function MyNames() {
  const { address, isConnected } = useAccount();
  const { data, isLoading, error } = useQuery({
    queryKey: ["myNames", address],
    queryFn: () => fetchNamesByOwner(address!),
    enabled: Boolean(address),
    refetchInterval: 20_000,
  });

  if (!isConnected) {
    return <div className="empty">connect a wallet to see your names</div>;
  }
  if (isLoading) {
    return (
      <div className="card row">
        <div className="progress-ring" /> loading your names…
      </div>
    );
  }
  if (error) {
    return (
      <div className="empty">couldn&rsquo;t reach the index — it may still be syncing</div>
    );
  }

  const now = Math.floor(Date.now() / 1000);
  const names = data?.names ?? [];
  const subnames = data?.subnames ?? [];

  return (
    <>
      <div className="card">
        <h3>Names</h3>
        {names.length === 0 && (
          <p className="muted small mono">
            No bands yet. <Link href="/">Search for one above.</Link>
          </p>
        )}
        {names.map((n) => {
          const expires = Number(n.expiresAt);
          const expiringSoon = expires - now < 30 * 86400 && expires > now;
          const expired = expires <= now;
          return (
            <Link
              className="name-row"
              key={n.id}
              href={`/name/${encodeURIComponent(n.label ?? "")}`}
              style={{ color: "inherit" }}
            >
              <div className="stack" style={{ gap: 8, alignItems: "flex-start" }}>
                <BandChip name={n.label ?? ""} size="sm" />
                <span className="muted small mono">
                  expires {formatDate(n.expiresAt)}
                </span>
              </div>
              <div className="row" style={{ flexWrap: "wrap", justifyContent: "flex-end" }}>
                {n.wrapped && <span className="tag">wrapped</span>}
                {expired ? (
                  <span className="tag danger">grace</span>
                ) : expiringSoon ? (
                  <span className="tag warn">renew soon</span>
                ) : null}
              </div>
            </Link>
          );
        })}
      </div>

      {subnames.length > 0 && (
        <div className="card">
          <h3>Subnames</h3>
          <div className="row wrap" style={{ gap: 10 }}>
            {subnames.map((s) => (
              <BandChip key={s.id} name={s.name} size="sm" />
            ))}
          </div>
        </div>
      )}
    </>
  );
}
