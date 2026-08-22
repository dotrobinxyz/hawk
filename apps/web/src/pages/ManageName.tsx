import { useMemo, useState } from "react";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { erc20Abi, isAddress, encodeFunctionData, type Address, type Hex } from "viem";
import {
  publicResolverAbi,
  reverseRegistrarAbi,
  hawkBaseRegistrarAbi,
  hawkRegistrarControllerAbi,
  hawkWrapperAbi,
  hawkNode,
  hawkTokenId,
  SECONDS_PER_YEAR,
  normalize,
} from "hawk-names";
import { ADDRESSES, CHAIN, EXPLORER } from "../config";
import { formatDate, formatEth, formatUSDC, shortAddress } from "../lib/format";
import { useTx } from "../lib/useTx";
import { BandChip } from "../components/BandChip";
import { CheckIcon } from "../components/icons";

const TEXT_KEYS = ["avatar", "url", "com.twitter", "org.telegram", "description"];
const PARENT_CANNOT_CONTROL = 0x10000;
const CANNOT_UNWRAP = 1;

export function ManageName({
  label,
  expires,
}: {
  label: string;
  expires: bigint;
}) {
  const { address } = useAccount();
  const node = useMemo(() => hawkNode(label), [label]);
  const tokenId = useMemo(() => hawkTokenId(label), [label]);

  const { data, refetch: refetchCore } = useReadContracts({
    contracts: [
      {
        address: ADDRESSES.baseRegistrar,
        abi: hawkBaseRegistrarAbi,
        functionName: "ownerOf",
        args: [tokenId],
      },
      {
        address: ADDRESSES.wrapper,
        abi: hawkWrapperAbi,
        functionName: "getData",
        args: [BigInt(node)],
      },
      {
        address: ADDRESSES.publicResolver,
        abi: publicResolverAbi,
        functionName: "addr",
        args: [node],
      },
      {
        address: ADDRESSES.baseRegistrar,
        abi: hawkBaseRegistrarAbi,
        functionName: "GRACE_PERIOD",
      },
    ],
  });

  const { data: textData, refetch: refetchTexts } = useReadContracts({
    contracts: TEXT_KEYS.map((key) => ({
      address: ADDRESSES.publicResolver,
      abi: publicResolverAbi,
      functionName: "text",
      args: [node, key],
    })),
  });

  const refetch = () => {
    void refetchCore();
    void refetchTexts();
  };

  const registrant = data?.[0]?.result as Address | undefined; // reverts in grace
  const wrapData = data?.[1]?.result as
    | readonly [Address, number, bigint]
    | undefined;
  const addrRecord = data?.[2]?.result as Address | undefined;
  const grace = (data?.[3]?.result as bigint | undefined) ?? 7776000n;
  const texts = TEXT_KEYS.map(
    (_, i) => (textData?.[i]?.result as string | undefined) ?? "",
  );

  const wrapped = Boolean(
    wrapData && wrapData[0] !== "0x0000000000000000000000000000000000000000",
  );
  const beneficialOwner = wrapped ? wrapData![0] : registrant;
  const isOwner =
    Boolean(address) &&
    Boolean(beneficialOwner) &&
    address!.toLowerCase() === beneficialOwner!.toLowerCase();

  const now = BigInt(Math.floor(Date.now() / 1000));
  const inGrace = expires > 0n && now > expires && now <= expires + grace;
  const expiringSoon =
    expires > 0n && now < expires && expires - now < 30n * 86400n;

  return (
    <>
      <div className="card card--night profile-hero">
        <BandChip name={label} variant="green-outline" size="xl" />
        <div className="chips">
          {isOwner && (
            <span className="tag reserved">
              <CheckIcon /> yours
            </span>
          )}
          <span className="tag">{wrapped ? "wrapped · ERC-1155" : "ERC-721"}</span>
          <span className="tag">expires {formatDate(expires)}</span>
          {inGrace && <span className="tag danger">in grace period</span>}
        </div>
      </div>

      <div className="card">
        <div className="kv">
          <span className="k">Owner</span>
          <span className="v mono">
            {beneficialOwner ? (
              EXPLORER ? (
                <a
                  href={`${EXPLORER}/address/${beneficialOwner}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  {shortAddress(beneficialOwner)}
                </a>
              ) : (
                shortAddress(beneficialOwner)
              )
            ) : inGrace ? (
              "in grace period"
            ) : (
              "—"
            )}
            {isOwner && " (you)"}
          </span>
        </div>
        <div className="kv">
          <span className="k">Points to</span>
          <span className="v mono">
            {addrRecord &&
            addrRecord !== "0x0000000000000000000000000000000000000000"
              ? shortAddress(addrRecord)
              : "not set"}
          </span>
        </div>
      </div>

      <RenewCard
        label={label}
        inGrace={inGrace}
        expiringSoon={expiringSoon}
        onDone={refetch}
      />

      {isOwner && (
        <>
          <RecordsCard
            label={label}
            node={node}
            currentAddr={addrRecord}
            currentTexts={texts}
            onDone={refetch}
          />
          <PrimaryCard label={label} />
          <WrapCard
            label={label}
            wrapped={wrapped}
            tokenId={tokenId}
            onDone={refetch}
          />
          {wrapped && (
            <SubnamesCard
              label={label}
              node={node}
              fuses={wrapData?.[1] ?? 0}
              wrapperExpiry={wrapData?.[2] ?? 0n}
              onDone={refetch}
            />
          )}
          <TransferCard
            label={label}
            wrapped={wrapped}
            tokenId={tokenId}
            node={node}
            onDone={refetch}
          />
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------

function RenewCard({
  label,
  inGrace,
  expiringSoon,
  onDone,
}: {
  label: string;
  inGrace: boolean;
  expiringSoon: boolean;
  onDone: () => void;
}) {
  const { address, isConnected } = useAccount();
  const { run, busy, error, walletClient, publicClient } = useTx();
  const [years, setYears] = useState(1);
  const [currency, setCurrency] = useState<"USDC" | "ETH">("USDC");
  const duration = BigInt(years) * SECONDS_PER_YEAR;

  const { data: usdcQuote } = useReadContract({
    address: ADDRESSES.controller,
    abi: hawkRegistrarControllerAbi,
    functionName: "rentPriceUSDC",
    args: [label, duration],
  });
  const { data: ethQuote } = useReadContract({
    address: ADDRESSES.controller,
    abi: hawkRegistrarControllerAbi,
    functionName: "rentPrice",
    args: [label, duration],
  });

  const quote = currency === "USDC" ? usdcQuote?.base : ethQuote?.base;

  async function renew() {
    if (!walletClient || !publicClient || !address) return;
    if (currency === "USDC") {
      const fresh = await publicClient.readContract({
        address: ADDRESSES.controller,
        abi: hawkRegistrarControllerAbi,
        functionName: "rentPriceUSDC",
        args: [label, duration],
      });
      const allowance = await publicClient.readContract({
        address: ADDRESSES.usdc,
        abi: erc20Abi,
        functionName: "allowance",
        args: [address, ADDRESSES.controller],
      });
      await run(
        "renew",
        [
          async () =>
            allowance >= fresh.base
              ? null
              : walletClient.writeContract({
                  address: ADDRESSES.usdc,
                  abi: erc20Abi,
                  functionName: "approve",
                  args: [ADDRESSES.controller, fresh.base],
                  chain: CHAIN,
                  account: address,
                }),
          async () =>
            walletClient.writeContract({
              address: ADDRESSES.controller,
              abi: hawkRegistrarControllerAbi,
              functionName: "renewWithUSDC",
              args: [label, duration, "0x".padEnd(66, "0") as Hex, fresh.base],
              chain: CHAIN,
              account: address,
            }),
        ],
        onDone,
      );
    } else {
      const fresh = await publicClient.readContract({
        address: ADDRESSES.controller,
        abi: hawkRegistrarControllerAbi,
        functionName: "rentPrice",
        args: [label, duration],
      });
      await run(
        "renew",
        [
          async () =>
            walletClient.writeContract({
              address: ADDRESSES.controller,
              abi: hawkRegistrarControllerAbi,
              functionName: "renew",
              args: [label, duration, "0x".padEnd(66, "0") as Hex],
              value: fresh.base,
              chain: CHAIN,
              account: address,
            }),
        ],
        onDone,
      );
    }
  }

  return (
    <div className="card">
      <h3 style={{ margin: "0 0 12px" }}>Extend registration</h3>
      {inGrace ? (
        <p className="notice danger small">
          In grace — renew now to keep {label}.hawk. After grace, it goes to
          public auction.
        </p>
      ) : expiringSoon ? (
        <p className="notice warn small">
          {label}.hawk expires soon. Renew to keep it.
        </p>
      ) : null}
      <div className="row wrap" style={{ gap: 12 }}>
        <div className="stepper">
          <button onClick={() => setYears(Math.max(1, years - 1))}>−</button>
          <span className="value">
            {years} {years === 1 ? "year" : "years"}
          </span>
          <button onClick={() => setYears(Math.min(10, years + 1))}>+</button>
        </div>
        <div className="seg" style={{ flex: 1, minWidth: 140 }}>
          <button
            className={currency === "USDC" ? "on" : ""}
            onClick={() => setCurrency("USDC")}
          >
            USDC
          </button>
          <button
            className={currency === "ETH" ? "on" : ""}
            onClick={() => setCurrency("ETH")}
          >
            ETH
          </button>
        </div>
      </div>
      <div className="row between" style={{ marginTop: 14 }}>
        <span className="muted">
          {quote === undefined
            ? "…"
            : currency === "USDC"
              ? formatUSDC(quote)
              : formatEth(quote)}
        </span>
        <button
          className="btn small"
          onClick={renew}
          disabled={!isConnected || busy !== null}
        >
          {busy ? <span className="progress-ring" /> : null} renew
        </button>
      </div>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------

function RecordsCard({
  label,
  node,
  currentAddr,
  currentTexts,
  onDone,
}: {
  label: string;
  node: Hex;
  currentAddr: Address | undefined;
  currentTexts: string[];
  onDone: () => void;
}) {
  const { address } = useAccount();
  const { run, busy, error, walletClient } = useTx();
  const [addrValue, setAddrValue] = useState<string | null>(null);
  const [textValues, setTextValues] = useState<Record<string, string>>({});

  const effectiveAddr =
    addrValue ??
    (currentAddr && currentAddr !== "0x0000000000000000000000000000000000000000"
      ? currentAddr
      : "");

  function textValue(key: string, index: number): string {
    return textValues[key] ?? currentTexts[index] ?? "";
  }

  const dirty =
    addrValue !== null || Object.keys(textValues).length > 0;

  async function save() {
    if (!walletClient || !address) return;
    const calls: Hex[] = [];
    if (addrValue !== null) {
      if (addrValue !== "" && !isAddress(addrValue)) return;
      calls.push(
        encodeFunctionData({
          abi: publicResolverAbi,
          functionName: "setAddr",
          args: [
            node,
            (addrValue === ""
              ? "0x0000000000000000000000000000000000000000"
              : addrValue) as Address,
          ],
        }),
      );
    }
    for (const [key, value] of Object.entries(textValues)) {
      calls.push(
        encodeFunctionData({
          abi: publicResolverAbi,
          functionName: "setText",
          args: [node, key, value],
        }),
      );
    }
    if (calls.length === 0) return;
    await run(
      "records",
      [
        async () =>
          walletClient.writeContract({
            address: ADDRESSES.publicResolver,
            abi: publicResolverAbi,
            functionName: "multicall",
            args: [calls],
            chain: CHAIN,
            account: address!,
          }),
      ],
      () => {
        setAddrValue(null);
        setTextValues({});
        onDone();
      },
    );
  }

  return (
    <div className="card">
      <h3 style={{ margin: "0 0 12px" }}>Records</h3>
      <div className="field">
        <label>Address ({label}.hawk points to)</label>
        <input
          className="input mono"
          placeholder="0x…"
          value={effectiveAddr}
          onChange={(e) => setAddrValue(e.target.value)}
        />
      </div>
      {TEXT_KEYS.map((key, i) => (
        <div className="field" key={key}>
          <label>{key}</label>
          <input
            className="input"
            value={textValue(key, i)}
            placeholder={key === "avatar" ? "https://… or eip155:… URI" : ""}
            onChange={(e) =>
              setTextValues((prev) => ({ ...prev, [key]: e.target.value }))
            }
          />
        </div>
      ))}
      <button
        className="btn block"
        onClick={save}
        disabled={!dirty || busy !== null}
      >
        {busy ? <span className="progress-ring" /> : null} save records
      </button>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------

function PrimaryCard({ label }: { label: string }) {
  const { address } = useAccount();
  const { run, busy, error, walletClient } = useTx();
  const full = `${label}.hawk`;

  return (
    <div className="card">
      <div className="row between wrap">
        <div>
          <h3 style={{ margin: 0 }}>Primary name</h3>
          <p className="small faint" style={{ margin: "4px 0 0" }}>
            Apps show {full} wherever your address appears.
          </p>
        </div>
        <button
          className="btn small"
          disabled={busy !== null}
          onClick={() =>
            run("primary", [
              async () =>
                walletClient!.writeContract({
                  address: ADDRESSES.reverseRegistrar,
                  abi: reverseRegistrarAbi,
                  functionName: "setName",
                  args: [full],
                  chain: CHAIN,
                  account: address!,
                }),
            ])
          }
        >
          {busy ? <span className="progress-ring" /> : null} make primary
        </button>
      </div>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------

function WrapCard({
  label,
  wrapped,
  tokenId,
  onDone,
}: {
  label: string;
  wrapped: boolean;
  tokenId: bigint;
  onDone: () => void;
}) {
  const { address } = useAccount();
  const { run, busy, error, walletClient, publicClient } = useTx();

  async function wrap() {
    if (!walletClient || !publicClient || !address) return;
    const approved = await publicClient.readContract({
      address: ADDRESSES.baseRegistrar,
      abi: hawkBaseRegistrarAbi,
      functionName: "isApprovedForAll",
      args: [address, ADDRESSES.wrapper],
    });
    await run(
      "wrap",
      [
        async () =>
          approved
            ? null
            : walletClient.writeContract({
                address: ADDRESSES.baseRegistrar,
                abi: hawkBaseRegistrarAbi,
                functionName: "setApprovalForAll",
                args: [ADDRESSES.wrapper, true],
                chain: CHAIN,
                account: address,
              }),
        async () =>
          walletClient.writeContract({
            address: ADDRESSES.wrapper,
            abi: hawkWrapperAbi,
            functionName: "wrapETH2LD",
            args: [label, address, 0, ADDRESSES.publicResolver],
            chain: CHAIN,
            account: address,
          }),
      ],
      onDone,
    );
  }

  async function unwrap() {
    if (!walletClient || !address) return;
    await run(
      "unwrap",
      [
        async () =>
          walletClient.writeContract({
            address: ADDRESSES.wrapper,
            abi: hawkWrapperAbi,
            functionName: "unwrapETH2LD",
            args: [
              `0x${tokenId.toString(16).padStart(64, "0")}` as Hex,
              address,
              address,
            ],
            chain: CHAIN,
            account: address,
          }),
      ],
      onDone,
    );
  }

  return (
    <div className="card">
      <div className="row between wrap">
        <div>
          <h3 style={{ margin: 0 }}>{wrapped ? "Wrapped" : "Wrap"}</h3>
          <p className="small faint" style={{ margin: "4px 0 0" }}>
            {wrapped
              ? "This name is an ERC-1155 and can issue tradeable subnames."
              : "Wrapping lets you issue subnames as real, tradeable tokens."}
          </p>
        </div>
        <button
          className="btn small secondary"
          disabled={busy !== null}
          onClick={wrapped ? unwrap : wrap}
        >
          {busy ? <span className="progress-ring" /> : null}
          {wrapped ? "unwrap" : "wrap"}
        </button>
      </div>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------

function SubnamesCard({
  label,
  node,
  fuses,
  wrapperExpiry,
  onDone,
}: {
  label: string;
  node: Hex;
  fuses: number;
  wrapperExpiry: bigint;
  onDone: () => void;
}) {
  const { address } = useAccount();
  const { run, busy, error, setError, walletClient } = useTx();
  const [sublabel, setSublabel] = useState("");
  const [to, setTo] = useState("");
  const [emancipate, setEmancipate] = useState(false);

  async function issue() {
    if (!walletClient || !address) return;
    let normalized: string;
    try {
      normalized = normalize(sublabel.trim());
      if (!normalized || normalized.includes(".")) throw new Error();
    } catch {
      setError("Enter a single valid label (no dots).");
      return;
    }
    const owner = (to.trim() === "" ? address : to.trim()) as Address;
    if (!isAddress(owner)) {
      setError("Owner must be a valid address.");
      return;
    }
    const needsUnwrapBurn = emancipate && (fuses & CANNOT_UNWRAP) === 0;
    await run(
      "subname",
      [
        async () =>
          needsUnwrapBurn
            ? walletClient.writeContract({
                address: ADDRESSES.wrapper,
                abi: hawkWrapperAbi,
                functionName: "setFuses",
                args: [node, CANNOT_UNWRAP],
                chain: CHAIN,
                account: address,
              })
            : null,
        async () =>
          walletClient.writeContract({
            address: ADDRESSES.wrapper,
            abi: hawkWrapperAbi,
            functionName: "setSubnodeOwner",
            args: [
              node,
              normalized,
              owner,
              emancipate ? PARENT_CANNOT_CONTROL : 0,
              emancipate ? BigInt(wrapperExpiry) : 0n,
            ],
            chain: CHAIN,
            account: address,
          }),
      ],
      () => {
        setSublabel("");
        setTo("");
        onDone();
      },
    );
  }

  return (
    <div className="card">
      <h3 style={{ margin: "0 0 4px" }}>Issue a subname</h3>
      <p className="small faint" style={{ margin: "0 0 12px" }}>
        agent1.{label}.hawk for your bots, or holder names for your
        community — each one a real ERC-1155 its owner can trade.
      </p>
      <div className="field">
        <label>Subname</label>
        <input
          className="input"
          placeholder="agent1"
          value={sublabel}
          onChange={(e) => setSublabel(e.target.value)}
          autoCapitalize="none"
        />
        {sublabel.trim() !== "" && (
          <div style={{ marginTop: 10 }}>
            <BandChip name={`${sublabel.trim()}.${label}`} size="sm" />
          </div>
        )}
      </div>
      <div className="field">
        <label>Owner (default: you)</label>
        <input
          className="input mono"
          placeholder="0x…"
          value={to}
          onChange={(e) => setTo(e.target.value)}
        />
      </div>
      <label className="row" style={{ marginBottom: 14, cursor: "pointer" }}>
        <input
          type="checkbox"
          checked={emancipate}
          onChange={(e) => setEmancipate(e.target.checked)}
        />
        <span className="small muted">
          Emancipate — you permanently give up control over this subname (and
          lock this name against unwrapping)
        </span>
      </label>
      <button
        className="btn block"
        onClick={issue}
        disabled={busy !== null || sublabel.trim() === ""}
      >
        {busy ? <span className="progress-ring" /> : null} issue subname
      </button>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------

function TransferCard({
  label,
  wrapped,
  tokenId,
  node,
  onDone,
}: {
  label: string;
  wrapped: boolean;
  tokenId: bigint;
  node: Hex;
  onDone: () => void;
}) {
  const { address } = useAccount();
  const { run, busy, error, setError, walletClient } = useTx();
  const [to, setTo] = useState("");

  async function transfer() {
    if (!walletClient || !address) return;
    const target = to.trim() as Address;
    if (!isAddress(target)) {
      setError("Enter a valid recipient address.");
      return;
    }
    await run(
      "transfer",
      [
        async () =>
          wrapped
            ? walletClient.writeContract({
                address: ADDRESSES.wrapper,
                abi: hawkWrapperAbi,
                functionName: "safeTransferFrom",
                args: [address, target, BigInt(node), 1n, "0x"],
                chain: CHAIN,
                account: address,
              })
            : walletClient.writeContract({
                address: ADDRESSES.baseRegistrar,
                abi: hawkBaseRegistrarAbi,
                functionName: "safeTransferFrom",
                args: [address, target, tokenId],
                chain: CHAIN,
                account: address,
              }),
      ],
      () => {
        setTo("");
        onDone();
      },
    );
  }

  return (
    <div className="card">
      <h3 style={{ margin: "0 0 12px" }}>Transfer</h3>
      <div className="row">
        <input
          className="input mono"
          placeholder="Recipient 0x…"
          value={to}
          onChange={(e) => setTo(e.target.value)}
        />
        <button
          className="btn danger small"
          onClick={transfer}
          disabled={busy !== null || to.trim() === ""}
        >
          {busy ? <span className="progress-ring" /> : null} send
        </button>
      </div>
      <p className="small faint" style={{ margin: "10px 0 0" }}>
        Transfers the {wrapped ? "wrapped ERC-1155" : "ERC-721"} token.
        {!wrapped &&
          " The new owner should call reclaim to also take registry control."}
      </p>
      {error && <p className="notice danger small" style={{ marginTop: 10 }}>{error}</p>}
    </div>
  );
}
