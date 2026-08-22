import { index, onchainTable, primaryKey } from "ponder";

/// A .hawk second-level name (one row per labelhash, ever registered).
export const name = onchainTable(
  "name",
  (t) => ({
    /// labelhash (0x…)
    id: t.hex().primaryKey(),
    label: t.text(),
    node: t.hex().notNull(),
    /// current ERC-721 holder (the wrapper, if wrapped)
    registrant: t.hex().notNull(),
    /// beneficial owner: wrapper token holder when wrapped, else registrant
    owner: t.hex().notNull(),
    expiresAt: t.bigint().notNull(),
    registeredAt: t.bigint().notNull(),
    updatedAt: t.bigint().notNull(),
    wrapped: t.boolean().notNull().default(false),
    fuses: t.integer().notNull().default(0),
    resolver: t.hex(),
  }),
  (table) => ({
    ownerIdx: index().on(table.owner),
    expiresIdx: index().on(table.expiresAt),
    nodeIdx: index().on(table.node),
  }),
);

/// Wrapped subnames (every wrapper token that is not a .hawk 2LD).
export const subname = onchainTable(
  "subname",
  (t) => ({
    /// namehash of the full name
    id: t.hex().primaryKey(),
    /// full dotted name decoded from the wrapper's DNS encoding
    name: t.text().notNull(),
    parentNode: t.hex().notNull(),
    owner: t.hex().notNull(),
    fuses: t.integer().notNull().default(0),
    expiry: t.bigint().notNull().default(0n),
    createdAt: t.bigint().notNull(),
    updatedAt: t.bigint().notNull(),
  }),
  (table) => ({
    ownerIdx: index().on(table.owner),
    parentIdx: index().on(table.parentNode),
  }),
);

/// One row per registration or renewal transaction.
export const registrationEvent = onchainTable(
  "registration_event",
  (t) => ({
    /// txHash-logIndex
    id: t.text().primaryKey(),
    labelhash: t.hex().notNull(),
    label: t.text().notNull(),
    kind: t.text().notNull(), // "registration" | "renewal"
    owner: t.hex().notNull(),
    /// amounts in the payment asset's base units
    baseCost: t.bigint().notNull(),
    premium: t.bigint().notNull().default(0n),
    currency: t.text().notNull(), // "ETH" | "USDC"
    expiresAt: t.bigint().notNull(),
    referrer: t.hex(),
    txHash: t.hex().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    labelhashIdx: index().on(table.labelhash),
    timeIdx: index().on(table.timestamp),
  }),
);

/// Latest text record per (node, key).
export const textRecord = onchainTable(
  "text_record",
  (t) => ({
    node: t.hex().notNull(),
    key: t.text().notNull(),
    value: t.text(),
    updatedAt: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.node, table.key] }),
    nodeIdx: index().on(table.node),
  }),
);

/// Latest address record per (node, coinType). coinType 60 = chain address.
export const addressRecord = onchainTable(
  "address_record",
  (t) => ({
    node: t.hex().notNull(),
    coinType: t.bigint().notNull(),
    value: t.hex(),
    updatedAt: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.node, table.coinType] }),
    nodeIdx: index().on(table.node),
  }),
);

/// Latest contenthash per node.
export const contenthashRecord = onchainTable("contenthash_record", (t) => ({
  node: t.hex().primaryKey(),
  value: t.hex(),
  updatedAt: t.bigint().notNull(),
}));

/// addr.reverse node → address, learned from ReverseClaimed.
export const reverseNode = onchainTable("reverse_node", (t) => ({
  node: t.hex().primaryKey(),
  address: t.hex().notNull(),
}));

/// Primary name per address (reverse resolution), the adoption metric.
export const primaryName = onchainTable("primary_name", (t) => ({
  address: t.hex().primaryKey(),
  name: t.text(),
  updatedAt: t.bigint().notNull(),
}));

/// Reserved labels mirror.
export const reservedLabel = onchainTable("reserved_label", (t) => ({
  labelhash: t.hex().primaryKey(),
  label: t.text(),
  reserved: t.boolean().notNull(),
  updatedAt: t.bigint().notNull(),
}));

/// USDC payments awaiting correlation with their registration event (same tx).
export const usdcPayment = onchainTable("usdc_payment", (t) => ({
  /// txHash-labelhash
  id: t.text().primaryKey(),
  amount: t.bigint().notNull(),
  payer: t.hex().notNull(),
}));

/// Singleton counters.
export const stats = onchainTable("stats", (t) => ({
  id: t.integer().primaryKey(), // always 1
  names: t.bigint().notNull().default(0n),
  registrations: t.bigint().notNull().default(0n),
  renewals: t.bigint().notNull().default(0n),
  primaryNames: t.bigint().notNull().default(0n),
  ethRevenueWei: t.bigint().notNull().default(0n),
  usdcRevenue: t.bigint().notNull().default(0n),
}));
