import { useQuery } from "@tanstack/react-query";
import { useReadContract, useReadContracts } from "wagmi";
import { Link } from "wouter";
import {
  hawkBaseRegistrarAbi,
  hawkRegistrarControllerAbi,
  SECONDS_PER_YEAR,
} from "hawk-names";
import { ADDRESSES, PREMIUM_DAYS } from "../config";
import { fetchAuctionCandidates } from "../indexer";
import { formatCountdown, formatUSDC } from "../lib/format";
import { BandChip } from "../components/BandChip";
import { PREMIUM_NAMES, PREMIUM_CONTACT } from "../data/premiumNames";
import { PremiumBuy } from "../components/PremiumBuy";

export function Auctions() {
  const { data: grace } = useReadContract({
    address: ADDRESSES.baseRegistrar,
    abi: hawkBaseRegistrarAbi,
    functionName: "GRACE_PERIOD",
  });

  const { data: candidates } = useQuery({
    queryKey: ["auctions", grace?.toString()],
    queryFn: () =>
      fetchAuctionCandidates({
        graceSeconds: Number(grace),
        premiumDays: PREMIUM_DAYS,
      }),
    enabled: grace !== undefined,
    refetchInterval: 30_000,
  });

  const labels = (candidates ?? []).filter((c) => c.label);
  const { data: quotes } = useReadContracts({
    contracts: labels.map((c) => ({
      address: ADDRESSES.controller,
      abi: hawkRegistrarControllerAbi,
      functionName: "rentPriceUSDC" as const,
      args: [c.label!, SECONDS_PER_YEAR] as const,
    })),
    query: { enabled: labels.length > 0, refetchInterval: 30_000 },
  });

  const now = Math.floor(Date.now() / 1000);

  return (
    <>
      <div className="card card--night">
        <h3>Premium auctions</h3>
        <p className="muted small" style={{ margin: 0 }}>
          Expired names re-release through a falling-price auction — the premium
          starts at $1,000 and decays to zero over {PREMIUM_DAYS} days. Catch a
          name on the way down.
        </p>
      </div>

      {PREMIUM_NAMES.filter((p) => p.live).length > 0 && (
        <>
          <h2 className="section-title">Premium names</h2>
          <p className="muted small" style={{ marginTop: -6 }}>
            Held or reserved by the Hawk treasury for their namesakes —
            founders, CEOs, KOLs. Yours? Write to{" "}
            <a href={`mailto:${PREMIUM_CONTACT}`}>{PREMIUM_CONTACT}</a>; pay in
            USDC or ETH and the name transfers to your wallet.
          </p>
          <div className="card">
            {PREMIUM_NAMES.filter((p) => p.live).map((p) => (
              <div className="name-row" key={p.label}>
                <BandChip name={p.label} variant="night" size="sm" />
                <span className="premium-price">
                  ${p.priceUSD.toLocaleString("en-US")}
                </span>
                {p.reserved ? (
                  <a
                    className="muted small"
                    href={`mailto:${PREMIUM_CONTACT}?subject=${encodeURIComponent(
                      `${p.label}.hawk`,
                    )}`}
                  >
                    inquire
                  </a>
                ) : (
                  <PremiumBuy label={p.label} saleAddress={p.sale} />
                )}
              </div>
            ))}
          </div>
        </>
      )}

      <h2 className="section-title">Expiry auctions</h2>
      {labels.length === 0 ? (
        <div className="empty">no names in auction right now</div>
      ) : (
        <div className="card">
          {labels.map((c, i) => {
            const quote = quotes?.[i]?.result as
              | { base: bigint; premium: bigint }
              | undefined;
            const auctionEnds =
              Number(c.expiresAt) + Number(grace ?? 0n) + PREMIUM_DAYS * 86400;
            return (
              <Link
                className="name-row"
                key={c.id}
                href={`/name/${encodeURIComponent(c.label!)}`}
                style={{ color: "inherit" }}
              >
                <div className="stack" style={{ gap: 8, alignItems: "flex-start" }}>
                  <BandChip name={c.label!} size="sm" />
                  <span className="muted small mono">
                    ends in {formatCountdown(auctionEnds - now)}
                  </span>
                </div>
                <div style={{ textAlign: "right" }}>
                  <div className="mono" style={{ fontWeight: 500 }}>
                    {quote ? formatUSDC(quote.base + quote.premium) : "…"}
                  </div>
                  <div className="muted small mono">first year</div>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </>
  );
}
