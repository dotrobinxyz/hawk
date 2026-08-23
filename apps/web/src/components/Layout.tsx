import type { ReactNode } from "react";
import { Link, useRoute } from "wouter";
import { ConnectButton } from "./ConnectButton";
import { ADDRESSES, AGENTS_ENABLED, EXPLORER, NETWORK } from "../config";
import { shortAddress } from "../lib/format";

function NavLink({ href, label }: { href: string; label: string }) {
  const [active] = useRoute(href);
  return (
    <Link href={href} className={active ? "active" : ""}>
      {label}
    </Link>
  );
}

function ContractLine({
  label,
  address,
}: {
  label: string;
  address: `0x${string}`;
}) {
  const body = (
    <>
      <span className="muted">{label}</span>
      <span>{shortAddress(address)}</span>
    </>
  );
  return EXPLORER ? (
    <a
      className="contract-line"
      href={`${EXPLORER}/address/${address}`}
      target="_blank"
      rel="noreferrer"
    >
      {body}
    </a>
  ) : (
    <span className="contract-line">{body}</span>
  );
}

const githubIcon = (
  <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
    <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
  </svg>
);

const xIcon = (
  <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    <path d="M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z" />
  </svg>
);

const npmIcon = (
  <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    <path d="M0 0v24h24V0H0zm19.2 19.2h-2.4V9.6h-4.8v9.6H4.8V4.8h14.4v14.4z" />
  </svg>
);

const mailIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <rect x="3" y="5" width="18" height="14" rx="2.5" />
    <path d="m3.5 7 8.5 6.5L20.5 7" />
  </svg>
);

const shieldIcon = (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M12 2.5 4.5 5.3v5.9c0 4.6 3.2 7.9 7.5 9.3 4.3-1.4 7.5-4.7 7.5-9.3V5.3L12 2.5Z" />
  </svg>
);

/** Icon link in a circular band — the leg-band motif, applied to socials. */
function SocialBand({
  href,
  label,
  children,
}: {
  href: string;
  label: string;
  children: ReactNode;
}) {
  return (
    <a
      className="social-band"
      href={href}
      target={href.startsWith("mailto:") ? undefined : "_blank"}
      rel="noreferrer"
      aria-label={label}
      title={label}
    >
      {children}
    </a>
  );
}

export function Layout({ children }: { children: ReactNode }) {
  return (
    <div className="shell">
      <header className="topbar">
        <Link href="/" className="brand" aria-label="Hawk home">
          <img src="/hawk-mark.png" alt="" width={34} height={34} />
          <span className="wordmark">hawk</span>
          {NETWORK !== "base" && (
            <span className="tag reserved">
              {NETWORK === "local" ? "local" : "testnet"}
            </span>
          )}
        </Link>
        <ConnectButton />
      </header>

      <nav className="nav">
        <NavLink href="/" label="search" />
        <NavLink href="/my" label="my names" />
        <NavLink href="/auctions" label="auctions" />
        {AGENTS_ENABLED && <NavLink href="/agents" label="agents" />}
      </nav>

      <main>{children}</main>

      <footer className="footer">
        <div className="footer-brand">
          <img src="/hawk-mark.png" alt="" width={28} height={28} />
          <span className="wordmark">hawk</span>
        </div>
        <p>
          Agent identity on Base. ENS-standard resolution,
          on-chain SVG art, locked metadata.
        </p>
        <div className="contracts">
          <ContractLine label="registry" address={ADDRESSES.registry} />
          <ContractLine label="resolver" address={ADDRESSES.publicResolver} />
          <ContractLine label="registrar" address={ADDRESSES.baseRegistrar} />
        </div>
        <div className="links">
          <a href="https://docs.dothawk.xyz" target="_blank" rel="noreferrer">
            docs.dothawk.xyz
          </a>
          <a href="https://api.dothawk.xyz" target="_blank" rel="noreferrer">
            api.dothawk.xyz
          </a>
        </div>
        <div className="socials">
          <SocialBand href="https://github.com/dothawkxyz/hawk" label="github">
            {githubIcon}
          </SocialBand>
          <SocialBand
            href="https://www.npmjs.com/package/hawk-names"
            label="hawk-names on npm"
          >
            {npmIcon}
          </SocialBand>
          <SocialBand href="https://x.com/dothawkx" label="@dothawkx on x">
            {xIcon}
          </SocialBand>
          <SocialBand href="mailto:hello@dothawk.xyz" label="hello@dothawk.xyz">
            {mailIcon}
          </SocialBand>
          <SocialBand
            href="mailto:security@dothawk.xyz"
            label="security@dothawk.xyz"
          >
            {shieldIcon}
          </SocialBand>
        </div>
      </footer>
    </div>
  );
}
