import { ponder } from "ponder:registry";
import {
  addressRecord,
  bond,
  contenthashRecord,
  name,
  primaryName,
  registrationEvent,
  reservedLabel,
  reverseNode,
  stats,
  subname,
  textRecord,
  usdcPayment,
} from "ponder:schema";
import { eq } from "ponder";
import { keccak256, encodePacked, zeroAddress, type Hex } from "viem";

/// namehash("hawk")
const HAWK_NODE =
  "0xf431efc1fb1b854a38191ac67de7e1ee70205b40f71cb927c938685e82e05403" as const;

const STATS_ID = 1;

function nodeOf(labelhash: Hex): Hex {
  return keccak256(
    encodePacked(["bytes32", "bytes32"], [HAWK_NODE, labelhash]),
  );
}

/** Decodes a DNS-encoded name into its dotted form + label count. */
function decodeDns(dns: Hex): { name: string; labels: string[] } | null {
  const bytes = Buffer.from(dns.slice(2), "hex");
  const labels: string[] = [];
  let i = 0;
  while (i < bytes.length) {
    const len = bytes[i]!;
    if (len === 0) return { name: labels.join("."), labels };
    i += 1;
    if (i + len > bytes.length) return null;
    labels.push(bytes.subarray(i, i + len).toString("utf8"));
    i += len;
  }
  return null;
}

async function bumpStats(
  db: any,
  patch: (s: typeof stats.$inferSelect) => Partial<typeof stats.$inferSelect>,
) {
  const zero = {
    id: STATS_ID,
    names: 0n,
    registrations: 0n,
    renewals: 0n,
    primaryNames: 0n,
    ethRevenueWei: 0n,
    usdcRevenue: 0n,
  };
  await db
    .insert(stats)
    .values(zero)
    .onConflictDoNothing();
  const current = (await db.find(stats, { id: STATS_ID }))!;
  await db.update(stats, { id: STATS_ID }).set(patch(current));
}

// ---------------------------------------------------------------------------
// Controller — registrations, renewals, payments
// ---------------------------------------------------------------------------

ponder.on(
  "HawkRegistrarController:USDCPayment",
  async ({ event, context }) => {
    await context.db
      .insert(usdcPayment)
      .values({
        id: `${event.transaction.hash}-${event.args.labelhash}`,
        amount: event.args.amount,
        payer: event.args.payer,
      })
      .onConflictDoNothing();
    await bumpStats(context.db, (s) => ({
      usdcRevenue: s.usdcRevenue + event.args.amount,
    }));
  },
);

ponder.on(
  "HawkRegistrarController:NameRegistered",
  async ({ event, context }) => {
    const { label, labelhash, owner, baseCost, premium, expires, referrer } =
      event.args;
    const paid = await context.db.find(usdcPayment, {
      id: `${event.transaction.hash}-${labelhash}`,
    });
    const currency = paid ? "USDC" : "ETH";

    await context.db
      .insert(name)
      .values({
        id: labelhash,
        label,
        node: nodeOf(labelhash),
        registrant: owner,
        owner,
        expiresAt: expires,
        registeredAt: event.block.timestamp,
        updatedAt: event.block.timestamp,
        wrapped: false,
        fuses: 0,
      })
      .onConflictDoUpdate({
        label,
        expiresAt: expires,
        registeredAt: event.block.timestamp,
        updatedAt: event.block.timestamp,
      });

    await context.db.insert(registrationEvent).values({
      id: `${event.transaction.hash}-${event.log.logIndex}`,
      labelhash,
      label,
      kind: "registration",
      owner,
      baseCost,
      premium,
      currency,
      expiresAt: expires,
      referrer,
      txHash: event.transaction.hash,
      timestamp: event.block.timestamp,
    });

    await bumpStats(context.db, (s) => ({
      registrations: s.registrations + 1n,
      ethRevenueWei:
        currency === "ETH"
          ? s.ethRevenueWei + baseCost + premium
          : s.ethRevenueWei,
    }));
  },
);

ponder.on(
  "HawkRegistrarController:NameRenewed",
  async ({ event, context }) => {
    const { label, labelhash, cost, expires, referrer } = event.args;
    const paid = await context.db.find(usdcPayment, {
      id: `${event.transaction.hash}-${labelhash}`,
    });
    const currency = paid ? "USDC" : "ETH";

    await context.db
      .insert(registrationEvent)
      .values({
        id: `${event.transaction.hash}-${event.log.logIndex}`,
        labelhash,
        label,
        kind: "renewal",
        owner: event.transaction.from,
        baseCost: cost,
        premium: 0n,
        currency,
        expiresAt: expires,
        referrer,
        txHash: event.transaction.hash,
        timestamp: event.block.timestamp,
      })
      .onConflictDoNothing();

    await bumpStats(context.db, (s) => ({
      renewals: s.renewals + 1n,
      ethRevenueWei:
        currency === "ETH" ? s.ethRevenueWei + cost : s.ethRevenueWei,
    }));
  },
);

// ---------------------------------------------------------------------------
// Base registrar — canonical 721 state
// ---------------------------------------------------------------------------

ponder.on("HawkBaseRegistrar:NameRegistered", async ({ event, context }) => {
  const labelhash = `0x${event.args.id.toString(16).padStart(64, "0")}` as Hex;
  const existing = await context.db.find(name, { id: labelhash });
  if (existing) {
    await context.db.update(name, { id: labelhash }).set({
      registrant: event.args.owner,
      owner: event.args.owner,
      expiresAt: event.args.expires,
      registeredAt: event.block.timestamp,
      updatedAt: event.block.timestamp,
      // a fresh registration always starts unwrapped
      wrapped: false,
      fuses: 0,
    });
  } else {
    await context.db.insert(name).values({
      id: labelhash,
      node: nodeOf(labelhash),
      registrant: event.args.owner,
      owner: event.args.owner,
      expiresAt: event.args.expires,
      registeredAt: event.block.timestamp,
      updatedAt: event.block.timestamp,
      wrapped: false,
      fuses: 0,
    });
    await bumpStats(context.db, (s) => ({ names: s.names + 1n }));
  }
});

ponder.on("HawkBaseRegistrar:NameRenewed", async ({ event, context }) => {
  const labelhash = `0x${event.args.id.toString(16).padStart(64, "0")}` as Hex;
  const row = await context.db.find(name, { id: labelhash });
  if (row) {
    await context.db.update(name, { id: labelhash }).set({
      expiresAt: event.args.expires,
      updatedAt: event.block.timestamp,
    });
  }
});

ponder.on("HawkBaseRegistrar:Transfer", async ({ event, context }) => {
  const labelhash =
    `0x${event.args.tokenId.toString(16).padStart(64, "0")}` as Hex;
  const row = await context.db.find(name, { id: labelhash });
  if (!row) return; // mint mid-registration; NameRegistered will create it
  await context.db.update(name, { id: labelhash }).set({
    registrant: event.args.to,
    // beneficial owner follows the 721 unless the wrapper holds it
    owner: row.wrapped ? row.owner : event.args.to,
    updatedAt: event.block.timestamp,
  });
});

// ---------------------------------------------------------------------------
// Wrapper — wrapped names, subnames, fuses
// ---------------------------------------------------------------------------

ponder.on("HawkWrapper:NameWrapped", async ({ event, context }) => {
  const { node, owner, fuses, expiry } = event.args;
  const decoded = decodeDns(event.args.name);
  if (!decoded) return;

  const is2LD =
    decoded.labels.length === 2 && decoded.labels[1] === "hawk";

  if (is2LD) {
    const labelhash = keccak256(
      Buffer.from(decoded.labels[0]!, "utf8"),
    ) as Hex;
    const row = await context.db.find(name, { id: labelhash });
    if (row) {
      await context.db.update(name, { id: labelhash }).set({
        wrapped: true,
        owner,
        fuses: Number(fuses),
        label: row.label ?? decoded.labels[0]!,
        updatedAt: event.block.timestamp,
      });
    }
  } else {
    await context.db
      .insert(subname)
      .values({
        id: node,
        name: decoded.name,
        parentNode: parentNodeOf(decoded.labels),
        owner,
        fuses: Number(fuses),
        expiry,
        createdAt: event.block.timestamp,
        updatedAt: event.block.timestamp,
      })
      .onConflictDoUpdate({
        owner,
        fuses: Number(fuses),
        expiry,
        updatedAt: event.block.timestamp,
      });
  }
});

/** namehash of the parent of a dotted-label array (drop the first label). */
function parentNodeOf(labels: string[]): Hex {
  let node: Hex =
    "0x0000000000000000000000000000000000000000000000000000000000000000";
  for (let i = labels.length - 1; i >= 1; i--) {
    node = keccak256(
      encodePacked(
        ["bytes32", "bytes32"],
        [node, keccak256(Buffer.from(labels[i]!, "utf8"))],
      ),
    );
  }
  return node;
}

ponder.on("HawkWrapper:NameUnwrapped", async ({ event, context }) => {
  const { node, owner } = event.args;
  const nameRow = await findNameByNode(context.db, node);
  if (nameRow) {
    await context.db.update(name, { id: nameRow.id }).set({
      wrapped: false,
      owner,
      fuses: 0,
      updatedAt: event.block.timestamp,
    });
    return;
  }
  const sub = await context.db.find(subname, { id: node });
  if (sub) await context.db.delete(subname, { id: node });
});

async function findNameByNode(db: any, node: Hex) {
  const rows = await db.sql
    .select()
    .from(name)
    .where(eq(name.node, node))
    .limit(1);
  return rows[0] ?? null;
}

ponder.on("HawkWrapper:FusesSet", async ({ event, context }) => {
  const { node, fuses } = event.args;
  const nameRow = await findNameByNode(context.db, node);
  if (nameRow) {
    await context.db
      .update(name, { id: nameRow.id })
      .set({ fuses: Number(fuses), updatedAt: event.block.timestamp });
    return;
  }
  const sub = await context.db.find(subname, { id: node });
  if (sub) {
    await context.db
      .update(subname, { id: node })
      .set({ fuses: Number(fuses), updatedAt: event.block.timestamp });
  }
});

ponder.on("HawkWrapper:ExpiryExtended", async ({ event, context }) => {
  const sub = await context.db.find(subname, { id: event.args.node });
  if (sub) {
    await context.db
      .update(subname, { id: event.args.node })
      .set({ expiry: event.args.expiry, updatedAt: event.block.timestamp });
  }
});

ponder.on("HawkWrapper:TransferSingle", async ({ event, context }) => {
  await handleWrapperTransfer(
    context,
    event.args.id,
    event.args.to,
    event.block.timestamp,
  );
});

ponder.on("HawkWrapper:TransferBatch", async ({ event, context }) => {
  for (const id of event.args.ids) {
    await handleWrapperTransfer(
      context,
      id,
      event.args.to,
      event.block.timestamp,
    );
  }
});

async function handleWrapperTransfer(
  context: any,
  id: bigint,
  to: Hex,
  timestamp: bigint,
) {
  if (to === zeroAddress) return; // burns handled by unwrap/expiry
  const node = `0x${id.toString(16).padStart(64, "0")}` as Hex;
  const nameRow = await findNameByNode(context.db, node);
  if (nameRow && nameRow.wrapped) {
    await context.db
      .update(name, { id: nameRow.id })
      .set({ owner: to, updatedAt: timestamp });
    return;
  }
  const sub = await context.db.find(subname, { id: node });
  if (sub) {
    await context.db
      .update(subname, { id: node })
      .set({ owner: to, updatedAt: timestamp });
  }
}

// ---------------------------------------------------------------------------
// Registry + resolver — records
// ---------------------------------------------------------------------------

ponder.on("HawkRegistry:NewResolver", async ({ event, context }) => {
  const nameRow = await findNameByNode(context.db, event.args.node);
  if (nameRow) {
    await context.db
      .update(name, { id: nameRow.id })
      .set({ resolver: event.args.resolver, updatedAt: event.block.timestamp });
  }
});

ponder.on("PublicResolver:TextChanged", async ({ event, context }) => {
  await context.db
    .insert(textRecord)
    .values({
      node: event.args.node,
      key: event.args.key,
      value: event.args.value,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({
      value: event.args.value,
      updatedAt: event.block.timestamp,
    });
});

ponder.on("PublicResolver:AddrChanged", async ({ event, context }) => {
  await context.db
    .insert(addressRecord)
    .values({
      node: event.args.node,
      coinType: 60n,
      value: event.args.a,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({
      value: event.args.a,
      updatedAt: event.block.timestamp,
    });
});

ponder.on("PublicResolver:AddressChanged", async ({ event, context }) => {
  await context.db
    .insert(addressRecord)
    .values({
      node: event.args.node,
      coinType: event.args.coinType,
      value: event.args.newAddress,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({
      value: event.args.newAddress,
      updatedAt: event.block.timestamp,
    });
});

ponder.on("PublicResolver:ContenthashChanged", async ({ event, context }) => {
  await context.db
    .insert(contenthashRecord)
    .values({
      node: event.args.node,
      value: event.args.hash,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({
      value: event.args.hash,
      updatedAt: event.block.timestamp,
    });
});

// ---------------------------------------------------------------------------
// Reverse — primary names
// ---------------------------------------------------------------------------

ponder.on("ReverseRegistrar:ReverseClaimed", async ({ event, context }) => {
  await context.db
    .insert(reverseNode)
    .values({ node: event.args.node, address: event.args.addr })
    .onConflictDoUpdate({ address: event.args.addr });
});

ponder.on("PublicResolver:NameChanged", async ({ event, context }) => {
  const mapping = await context.db.find(reverseNode, {
    node: event.args.node,
  });
  if (!mapping) return; // a forward name record, not a reverse node

  const previous = await context.db.find(primaryName, {
    address: mapping.address,
  });
  const newName = event.args.name === "" ? null : event.args.name;
  await context.db
    .insert(primaryName)
    .values({
      address: mapping.address,
      name: newName,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({ name: newName, updatedAt: event.block.timestamp });

  const had = previous?.name != null;
  const has = newName != null;
  if (had !== has) {
    await bumpStats(context.db, (s) => ({
      primaryNames: s.primaryNames + (has ? 1n : -1n),
    }));
  }
});

// ---------------------------------------------------------------------------
// Reserved list
// ---------------------------------------------------------------------------

ponder.on("HawkReservedList:ReservationChanged", async ({ event, context }) => {
  await context.db
    .insert(reservedLabel)
    .values({
      labelhash: event.args.labelhash,
      label: event.args.label === "" ? null : event.args.label,
      reserved: event.args.reserved,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({
      reserved: event.args.reserved,
      updatedAt: event.block.timestamp,
    });
});

// ---------------------------------------------------------------------------
// Operator bonds (HawkBond)
// ---------------------------------------------------------------------------

async function bondLabel(context: { db: { sql: any } }, node: `0x${string}`): Promise<string | null> {
  const row = await context.db.sql
    .select()
    .from(name)
    .where(eq(name.node, node))
    .limit(1);
  return row[0]?.label ?? null;
}

ponder.on("HawkBond:Bonded", async ({ event, context }) => {
  const node = event.args.node as `0x${string}`;
  const label = await bondLabel(context, node);
  await context.db
    .insert(bond)
    .values({
      node,
      label,
      asset: event.args.asset,
      amount: event.args.amountNet,
      pendingAmount: 0n,
      unlockAt: 0n,
      since: event.block.timestamp,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate((row) => ({
      label,
      asset: event.args.asset,
      amount: row.amount + event.args.amountNet,
      updatedAt: event.block.timestamp,
    }));
});

ponder.on("HawkBond:WithdrawRequested", async ({ event, context }) => {
  const node = event.args.node as `0x${string}`;
  await context.db
    .update(bond, { node })
    .set((row) => ({
      amount: row.amount - event.args.amount,
      pendingAmount: row.pendingAmount + event.args.amount,
      unlockAt: BigInt(event.args.unlockAt),
      updatedAt: event.block.timestamp,
    }))
    .catch(() => {});
});

ponder.on("HawkBond:Withdrawn", async ({ event, context }) => {
  const node = event.args.node as `0x${string}`;
  await context.db
    .update(bond, { node })
    .set(() => ({
      pendingAmount: 0n,
      unlockAt: 0n,
      updatedAt: event.block.timestamp,
    }))
    .catch(() => {});
});
