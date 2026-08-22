/**
 * Curated premium names, held by the Hawk treasury (the Safe) and offered
 * to their namesakes. Listed on /auctions. Empty until Hawk deploys its own
 * premium-sale shop(s) on Base — populate per the Robin playbook.
 */
export type PremiumName = {
  label: string;
  priceUSD: number;
  /** true once the name is secured (sale-held or on-chain reserved) — only
   *  live names render, so the list is never a sniper's shopping list. */
  live: boolean;
  /** on-chain reserved (not yet registered) — inquire flow instead of buy. */
  reserved?: boolean;
  /** sale contract holding this name; defaults to SALE_ADDRESS. */
  sale?: `0x${string}`;
};

/** HawkPremiumSale contract; empty until deployed. */
export const SALE_ADDRESS = "" as `0x${string}` | "";

export const PREMIUM_NAMES: PremiumName[] = [];

export const PREMIUM_CONTACT = "hello@dothawk.xyz";
