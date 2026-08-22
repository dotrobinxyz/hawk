import { formatEther } from "viem";

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function formatUSDC(units: bigint): string {
  const dollars = Number(units) / 1e6;
  return dollars.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: dollars >= 100 ? 0 : 2,
  });
}

export function formatEth(wei: bigint): string {
  const eth = Number(formatEther(wei));
  if (eth === 0) return "0 ETH";
  if (eth < 0.0001) return "<0.0001 ETH";
  return `${eth.toLocaleString("en-US", { maximumFractionDigits: 4 })} ETH`;
}

export function formatDate(ts: bigint | number | string): string {
  return new Date(Number(ts) * 1000).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export function formatCountdown(seconds: number): string {
  if (seconds <= 0) return "now";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

/** Lifecycle of a name relative to now. */
export function nameStatus(
  expiresAt: bigint,
  graceSeconds: bigint,
): "active" | "expiring-soon" | "in-grace" | "in-auction-or-free" {
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (now <= expiresAt) {
    return expiresAt - now < 30n * 86400n ? "expiring-soon" : "active";
  }
  if (now <= expiresAt + graceSeconds) return "in-grace";
  return "in-auction-or-free";
}
