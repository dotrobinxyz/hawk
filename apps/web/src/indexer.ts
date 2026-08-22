import { INDEXER_URL } from "./config";

async function gql<T>(
  query: string,
  variables?: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(`${INDEXER_URL}/graphql`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`indexer ${res.status}`);
  const body = (await res.json()) as { data?: T; errors?: { message: string }[] };
  if (body.errors?.length) throw new Error(body.errors[0]!.message);
  return body.data as T;
}

export type IndexedName = {
  id: `0x${string}`;
  label: string | null;
  node: `0x${string}`;
  owner: `0x${string}`;
  registrant: `0x${string}`;
  expiresAt: string;
  wrapped: boolean;
  fuses: number;
};

export type IndexedSubname = {
  id: `0x${string}`;
  name: string;
  parentNode: `0x${string}`;
  owner: `0x${string}`;
  fuses: number;
  expiry: string;
};

export async function fetchNamesByOwner(owner: string): Promise<{
  names: IndexedName[];
  subnames: IndexedSubname[];
}> {
  const data = await gql<{
    names: { items: IndexedName[] };
    subnames: { items: IndexedSubname[] };
  }>(
    `query ($owner: String!) {
      names(where: { owner: $owner }, orderBy: "expiresAt", orderDirection: "asc", limit: 200) {
        items { id label node owner registrant expiresAt wrapped fuses }
      }
      subnames(where: { owner: $owner }, orderBy: "createdAt", orderDirection: "desc", limit: 200) {
        items { id name parentNode owner fuses expiry }
      }
    }`,
    { owner: owner.toLowerCase() },
  );
  return { names: data.names.items, subnames: data.subnames.items };
}

/** Names whose grace has ended but whose premium auction window is open. */
export async function fetchAuctionCandidates(params: {
  graceSeconds: number;
  premiumDays: number;
}): Promise<IndexedName[]> {
  const now = Math.floor(Date.now() / 1000);
  const graceEndedBefore = now - params.graceSeconds;
  const auctionStillOpenAfter =
    graceEndedBefore - params.premiumDays * 86400;
  const data = await gql<{ names: { items: IndexedName[] } }>(
    `query ($lt: BigInt!, $gt: BigInt!) {
      names(
        where: { expiresAt_lt: $lt, expiresAt_gt: $gt }
        orderBy: "expiresAt"
        orderDirection: "desc"
        limit: 100
      ) {
        items { id label node owner registrant expiresAt wrapped fuses }
      }
    }`,
    {
      lt: String(graceEndedBefore),
      gt: String(auctionStillOpenAfter),
    },
  );
  return data.names.items;
}

export type ActivityItem = {
  id: string;
  label: string;
  kind: string;
  currency: string;
  baseCost: string;
  premium: string;
  owner: `0x${string}`;
  timestamp: string;
  expiresAt: string;
};

export async function fetchRecentActivity(): Promise<ActivityItem[]> {
  const data = await gql<{ registrationEvents: { items: ActivityItem[] } }>(
    `{
      registrationEvents(orderBy: "timestamp", orderDirection: "desc", limit: 25) {
        items { id label kind currency baseCost premium owner timestamp expiresAt }
      }
    }`,
  );
  return data.registrationEvents.items;
}

export type Stats = {
  names: string;
  registrations: string;
  renewals: string;
  primaryNames: string;
};

export async function fetchStats(): Promise<Stats | null> {
  const data = await gql<{ statss: { items: Stats[] } }>(
    `{ statss(limit: 1) { items { names registrations renewals primaryNames } } }`,
  );
  return data.statss.items[0] ?? null;
}
