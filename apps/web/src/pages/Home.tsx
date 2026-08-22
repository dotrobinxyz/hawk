import { useState, type FormEvent } from "react";
import { useLocation } from "wouter";
import { useQuery } from "@tanstack/react-query";
import { normalize } from "hawk-names";
import { fetchRecentActivity } from "../indexer";
import { BandChip, type BandVariant } from "../components/BandChip";
import { usePromo } from "../hooks/usePromo";

export function Home() {
  const [, navigate] = useLocation();
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const promo = usePromo();

  const { data: activity } = useQuery({
    queryKey: ["activity"],
    queryFn: fetchRecentActivity,
    refetchInterval: 20_000,
  });

  function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    const raw = query.trim().replace(/\.hawk$/i, "");
    if (!raw) return;
    let label: string;
    try {
      label = normalize(raw);
    } catch {
      setError("that name contains unsupported characters.");
      return;
    }
    if (label.includes(".")) {
      setError("search a name without dots — subnames come from a parent name.");
      return;
    }
    if ([...label].length < 3) {
      setError("names are at least 3 characters.");
      return;
    }
    navigate(`/name/${encodeURIComponent(label)}`);
  }

  const recent = activity ?? [];

  return (
    <>
      <section className="hero">
        <h1>Name your agents.</h1>
        <p>
          Identity for the agent economy on Base. Every wallet, bot, and fleet
          gets a name that resolves anywhere, proves who it answers to, and
          carries its own capability card.
        </p>
        <form className="search" onSubmit={submit}>
          <input
            placeholder="find your .hawk"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="search"
            aria-label="Search for a name"
          />
          {query.trim() !== "" && <span className="suffix">.hawk</span>}
          <button className="btn" type="submit">
            search
          </button>
        </form>
        {error && <p className="form-error">{error}</p>}
        {promo.active && (
          <div className="promo-chip">
            launch promo — 5+ letter names 50% off until {promo.endsLabel}
          </div>
        )}
      </section>

      {recent.length > 0 && (
        <div className="ticker" aria-label="Recently banded names">
          <span className="ticker-label">recently banded</span>
          <div className="track-wrap">
            <div className="track">
              {[...recent, ...recent].map((item, i) => {
                // On the night strip, green suffix / green fills do the glowing.
                const variant: BandVariant =
                  i % 3 === 0 ? "green" : "green-outline";
                return (
                  <BandChip
                    key={`${item.id}-${i}`}
                    name={item.label}
                    variant={variant}
                    size="sm"
                  />
                );
              })}
            </div>
          </div>
        </div>
      )}

      <h2 className="section-title">One name per operator. One per agent.</h2>
      <p className="section-lede">
        Agents transact, hold funds, and talk to each other — they need
        addressable, verifiable identity. Under your name, each agent gets a
        subname that cryptographically proves it&rsquo;s yours.
      </p>
      <div className="agent-tree card--night">
        <BandChip name="acme" variant="green-outline" size="md" />
        <div className="agent-branch">
          <BandChip name="bot1.acme" variant="green-outline" size="sm" />
          <BandChip name="trader.acme" variant="green-outline" size="sm" />
          <BandChip name="ops.acme" variant="green-outline" size="sm" />
        </div>
      </div>
      <div className="agent-points">
        <div>
          <h4>Verifiable delegation</h4>
          <p>
            <code>bot1.acme.hawk</code> hangs off <code>acme.hawk</code> —
            counterparties walk the chain to the operator. An agent is yours or
            it doesn&rsquo;t resolve.
          </p>
        </div>
        <div>
          <h4>Capability cards</h4>
          <p>
            Text records are the agent&rsquo;s machine-readable profile —
            endpoint, <code>agent.capabilities</code>, model, operator — readable
            by any counterparty in one call.
          </p>
        </div>
        <div>
          <h4>Revocable &amp; tradeable</h4>
          <p>
            Subnames are ERC-1155 tokens. Replace a compromised agent, emancipate
            one to stand on its own, or sell a bot with its whole identity intact.
          </p>
        </div>
      </div>

      <h2 className="section-title" id="pricing">
        Pricing
      </h2>
      <div className="price-grid">
        <div className="price-card night">
          <div className="tier">3 characters</div>
          <div className="amt">
            $100<span className="per">/yr</span>
          </div>
          <p>The rare tier. Deep navy, full weight.</p>
        </div>
        <div className="price-card green">
          <div className="tier">4 characters</div>
          <div className="amt">
            $25<span className="per">/yr</span>
          </div>
          <p>Short and loud. Electric blue.</p>
        </div>
        <div className="price-card">
          <div className="tier">5+ characters</div>
          {promo.active ? (
            <>
              <div className="amt">
                $2.50<span className="per">/yr</span>
                <span className="was">$5</span>
              </div>
              <div className="promo-tag">50% off until {promo.endsLabel}</div>
            </>
          ) : (
            <div className="amt">
              $5<span className="per">/yr</span>
            </div>
          )}
          <p>Everyday names. Clean paper.</p>
        </div>
      </div>

      <h2 className="section-title">Who it&rsquo;s for</h2>
      <div>
        <div className="audience">
          <h3>For operators</h3>
          <div>
            <p>
              Register your name, issue a subname per agent, point each at its
              smart account, and revoke or sell any of them. Run a fleet of ten
              or ten thousand under one identity.
            </p>
            <div className="row wrap" style={{ gap: 8 }}>
              <BandChip name="bot1.acme" size="sm" />
              <BandChip name="rebalancer.acme" size="sm" />
            </div>
          </div>
        </div>
        <div className="audience">
          <h3>For builders</h3>
          <div>
            <p>
              Stock viem/wagmi/ethers resolve <code>.hawk</code> unchanged —
              verify a counterparty agent in one call.
            </p>
            <code className="codeblock">
              const name = await client.getEnsName(&#123; address &#125;)
            </code>
          </div>
        </div>
        <div className="audience">
          <h3>For everyone</h3>
          <div>
            <p>
              Not just agents — your wallet gets a name too. Set it once and
              every app on Base shows you as your name, not your address.
            </p>
            <BandChip name="maria" size="sm" />
          </div>
        </div>
      </div>
    </>
  );
}
