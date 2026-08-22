import type { Registration } from "hawk-names";
import type { Hex } from "viem";

/**
 * A commit-reveal registration in flight. Persisted to localStorage so a
 * refresh (or a wallet-app roundtrip on mobile) never loses the secret
 * between commit and reveal.
 */
export type PendingRegistration = {
  registration: Registration;
  commitment: Hex;
  /** unix seconds when the commit tx landed (set optimistically at send). */
  committedAt: number;
  currency: "USDC" | "ETH";
};

const key = (chainId: number, label: string) =>
  `hawk:pending:${chainId}:${label}`;

export function savePending(
  chainId: number,
  pending: PendingRegistration,
): void {
  localStorage.setItem(
    key(chainId, pending.registration.label),
    JSON.stringify(pending, (_, v) =>
      typeof v === "bigint" ? `#bigint:${v}` : v,
    ),
  );
}

export function loadPending(
  chainId: number,
  label: string,
): PendingRegistration | null {
  const raw = localStorage.getItem(key(chainId, label));
  if (!raw) return null;
  try {
    return JSON.parse(raw, (_, v) =>
      typeof v === "string" && v.startsWith("#bigint:")
        ? BigInt(v.slice(8))
        : v,
    ) as PendingRegistration;
  } catch {
    return null;
  }
}

export function clearPending(chainId: number, label: string): void {
  localStorage.removeItem(key(chainId, label));
}
