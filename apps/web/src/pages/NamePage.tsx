import { useEffect, useMemo, useState } from "react";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { encodeFunctionData, type Hex } from "viem";
import {
  makeCommitment,
  makeRegistration,
  publicResolverAbi,
  randomSecret,
  hawkBaseRegistrarAbi,
  hawkNode,
  hawkRegistrarControllerAbi,
  hawkReservedListAbi,
  hawkTokenId,
  REVERSE_RECORD_CHAIN,
  SECONDS_PER_YEAR,
  type Registration,
} from "hawk-names";
import { erc20Abi } from "viem";
import { ADDRESSES, CHAIN, NETWORK } from "../config";
import { usePromo } from "../hooks/usePromo";
import {
  clearPending,
  loadPending,
  savePending,
  type PendingRegistration,
} from "../lib/pending";
import { formatEth, formatUSDC } from "../lib/format";
import { useTx } from "../lib/useTx";
import { BandChip } from "../components/BandChip";
import { LockIcon } from "../components/icons";
import { ManageName } from "./ManageName";

const MIN_COMMIT_AGE = 60; // seconds; matches all deployed configs

export function NamePage({ label }: { label: string }) {
  const tokenId = useMemo(() => hawkTokenId(label), [label]);
  const [justBanded, setJustBanded] = useState(false);

  useEffect(() => {
    document.title = `${label}.hawk — hawk`;
    return () => {
      document.title = "hawk — names on Base";
    };
  }, [label]);

  const { data, refetch } = useReadContracts({
    contracts: [
      {
        address: ADDRESSES.controller,
        abi: hawkRegistrarControllerAbi,
        functionName: "available",
        args: [label],
      },
      {
        address: ADDRESSES.controller,
        abi: hawkRegistrarControllerAbi,
        functionName: "valid",
        args: [label],
      },
      {
        address: ADDRESSES.reservedList,
        abi: hawkReservedListAbi,
        functionName: "isReserved",
        args: [label],
      },
      {
        address: ADDRESSES.baseRegistrar,
        abi: hawkBaseRegistrarAbi,
        functionName: "nameExpires",
        args: [tokenId],
      },
    ],
    query: { refetchInterval: 15_000 },
  });

  const [available, valid, reserved, expires] = [
    data?.[0]?.result as boolean | undefined,
    data?.[1]?.result as boolean | undefined,
    data?.[2]?.result as boolean | undefined,
    data?.[3]?.result as bigint | undefined,
  ];

  if (data === undefined) {
    return (
      <div className="card row">
        <div className="progress-ring" /> checking availability…
      </div>
    );
  }

  // Registered → full management view (renders its own name hero).
  if (!reserved && valid !== false && !available) {
    return (
      <>
        {justBanded && (
          <div className="toast" style={{ marginBottom: 14 }}>
            Banded. <BandChip name={label} size="sm" /> is yours.
          </div>
        )}
        <ManageName label={label} expires={expires ?? 0n} />
      </>
    );
  }

  return (
    <>
      <div className="card card--night profile-hero">
        <BandChip name={label} variant="green-outline" size="xl" />
        <div className="chips">
          {reserved ? (
            <span className="tag reserved">
              <LockIcon /> reserved
            </span>
          ) : valid === false ? (
            <span className="tag gray">unavailable</span>
          ) : (
            <span className="tag available">available</span>
          )}
        </div>
      </div>

      {reserved ? (
        <div className="card">
          <p className="muted" style={{ margin: 0 }}>
            This name is reserved — stock tickers, chain protocol names, and
            brand-abuse terms are held back and never sold. Reservations can be
            released case by case.
          </p>
        </div>
      ) : valid === false ? (
        <div className="card">
          <p className="muted" style={{ margin: 0 }}>
            Names must be at least 3 characters.
          </p>
        </div>
      ) : (
        <RegisterFlow
          label={label}
          onRegistered={() => {
            setJustBanded(true);
            refetch();
          }}
        />
      )}
    </>
  );
}

// ---------------------------------------------------------------------------

type Step = "configure" | "committing" | "waiting" | "ready" | "registering";

function RegisterFlow({
  label,
  onRegistered,
}: {
  label: string;
  onRegistered: () => void;
}) {
  const { address, isConnected } = useAccount();
  const { run, busy, error, setError, walletClient, publicClient } = useTx();

  const [years, setYears] = useState(1);
  const [currency, setCurrency] = useState<"USDC" | "ETH">("USDC");
  const [setPrimary, setSetPrimary] = useState(true);
  const [pending, setPending] = useState<PendingRegistration | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  const duration = BigInt(years) * SECONDS_PER_YEAR;

  useEffect(() => {
    setPending(loadPending(CHAIN.id, label));
  }, [label]);

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  const quoteDuration = pending?.registration.duration ?? duration;
  const { data: usdcQuote } = useReadContract({
    address: ADDRESSES.controller,
    abi: hawkRegistrarControllerAbi,
    functionName: "rentPriceUSDC",
    args: [label, quoteDuration],
    query: { refetchInterval: 12_000 },
  });
  const { data: ethQuote } = useReadContract({
    address: ADDRESSES.controller,
    abi: hawkRegistrarControllerAbi,
    functionName: "rentPrice",
    args: [label, quoteDuration],
    query: { refetchInterval: 12_000 },
  });

  const activeCurrency = pending?.currency ?? currency;
  const quote = activeCurrency === "USDC" ? usdcQuote : ethQuote;
  const total = quote ? quote.base + quote.premium : undefined;
  const promo = usePromo();

  const step: Step = !pending
    ? "configure"
    : now < pending.committedAt + MIN_COMMIT_AGE
      ? "waiting"
      : busy === "register"
        ? "registering"
        : "ready";

  async function commit() {
    if (!walletClient || !address) return;
    const registration = makeRegistration({
      label,
      owner: address,
      duration,
      secret: randomSecret(),
      resolver: ADDRESSES.publicResolver,
      data: [
        encodeFunctionData({
          abi: publicResolverAbi,
          functionName: "setAddr",
          args: [hawkNode(label), address],
        }),
      ],
      reverseRecord: setPrimary ? REVERSE_RECORD_CHAIN : 0,
    });
    const commitment = makeCommitment(registration);
    await run("commit", [
      async () =>
        walletClient.writeContract({
          address: ADDRESSES.controller,
          abi: hawkRegistrarControllerAbi,
          functionName: "commit",
          args: [commitment],
          chain: CHAIN,
          account: address,
        }),
    ]);
    const record: PendingRegistration = {
      registration,
      commitment,
      committedAt: Math.floor(Date.now() / 1000),
      currency,
    };
    savePending(CHAIN.id, record);
    setPending(record);
  }

  async function register() {
    if (!walletClient || !publicClient || !pending || !address) return;
    const registration = pending.registration as Registration;

    if (pending.currency === "USDC") {
      const fresh = await publicClient.readContract({
        address: ADDRESSES.controller,
        abi: hawkRegistrarControllerAbi,
        functionName: "rentPriceUSDC",
        args: [label, registration.duration],
      });
      const maxTotal = fresh.base + fresh.premium;
      const allowance = await publicClient.readContract({
        address: ADDRESSES.usdc,
        abi: erc20Abi,
        functionName: "allowance",
        args: [address, ADDRESSES.controller],
      });
      await run(
        "register",
        [
          async () =>
            allowance >= maxTotal
              ? null
              : walletClient.writeContract({
                  address: ADDRESSES.usdc,
                  abi: erc20Abi,
                  functionName: "approve",
                  args: [ADDRESSES.controller, maxTotal],
                  chain: CHAIN,
                  account: address,
                }),
          async () =>
            walletClient.writeContract({
              address: ADDRESSES.controller,
              abi: hawkRegistrarControllerAbi,
              functionName: "registerWithUSDC",
              args: [registration, maxTotal],
              chain: CHAIN,
              account: address,
            }),
        ],
        () => {
          clearPending(CHAIN.id, label);
          setPending(null);
          onRegistered();
        },
      );
    } else {
      const fresh = await publicClient.readContract({
        address: ADDRESSES.controller,
        abi: hawkRegistrarControllerAbi,
        functionName: "rentPrice",
        args: [label, registration.duration],
      });
      await run(
        "register",
        [
          async () =>
            walletClient.writeContract({
              address: ADDRESSES.controller,
              abi: hawkRegistrarControllerAbi,
              functionName: "register",
              args: [registration],
              value: fresh.base + fresh.premium,
              chain: CHAIN,
              account: address,
            }),
        ],
        () => {
          clearPending(CHAIN.id, label);
          setPending(null);
          onRegistered();
        },
      );
    }
  }

  function cancelPending() {
    clearPending(CHAIN.id, label);
    setPending(null);
    setError(null);
  }

  const premium = quote?.premium ?? 0n;

  return (
    <div className="card">
      {step === "configure" && (
        <>
          <div className="field">
            <label>Registration period</label>
            <div className="stepper">
              <button onClick={() => setYears(Math.max(1, years - 1))}>−</button>
              <span className="value">
                {years} {years === 1 ? "year" : "years"}
              </span>
              <button onClick={() => setYears(Math.min(10, years + 1))}>+</button>
            </div>
          </div>
          <div className="field">
            <label>Pay with</label>
            <div className="seg">
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
          <label
            className="row"
            style={{ marginBottom: 16, cursor: "pointer", alignItems: "flex-start" }}
          >
            <input
              type="checkbox"
              checked={setPrimary}
              onChange={(e) => setSetPrimary(e.target.checked)}
            />
            <span className="muted small">
              Set as my primary name — show {label}.hawk instead of my address
            </span>
          </label>
        </>
      )}

      {promo.active && [...label].length >= 5 && (
        <div className="promo-tag" style={{ marginBottom: 8 }}>
          50% launch promo applied — ends {promo.endsLabel}
        </div>
      )}
      <div className="price-line" style={{ marginBottom: 6 }}>
        <span className="amount">
          {total === undefined
            ? "…"
            : activeCurrency === "USDC"
              ? formatUSDC(total)
              : formatEth(total)}
        </span>
        <span className="muted small">
          {years > 1 && step === "configure" ? `for ${years} years` : "/ term"}
        </span>
      </div>
      {premium > 0n && (
        <p className="notice warn" style={{ marginTop: 10 }}>
          This name just left its grace period — the price includes a temporary
          premium that decays to zero over the auction window.
        </p>
      )}

      <hr className="divider" />

      {!isConnected ? (
        <p className="muted small" style={{ margin: 0 }}>
          Connect a wallet to register.
        </p>
      ) : step === "configure" ? (
        <button className="btn block" onClick={commit} disabled={busy !== null}>
          {busy === "commit" ? <span className="progress-ring" /> : null}
          start registration
        </button>
      ) : step === "waiting" ? (
        <div className="stack">
          <div className="row">
            <div className="progress-ring" />
            <span className="muted">
              locking in your name… {pending!.committedAt + MIN_COMMIT_AGE - now}s
            </span>
          </div>
          <p className="muted small" style={{ margin: 0 }}>
            A short wait prevents anyone from front-running your registration.
            Keep this page open — your progress survives refreshes.
          </p>
        </div>
      ) : (
        <div className="stack">
          <button className="btn block" onClick={register} disabled={busy !== null}>
            {busy === "register" ? <span className="progress-ring" /> : null}
            complete registration
          </button>
          <button className="btn small secondary" onClick={cancelPending}>
            start over
          </button>
          <p className="muted small" style={{ margin: 0 }}>
            Complete within 24 hours or the commitment expires.
          </p>
        </div>
      )}

      {error && (
        <p className="notice danger" style={{ marginTop: 12 }}>
          {error}
        </p>
      )}
      {NETWORK !== "base" && step === "configure" && (
        <p className="muted small" style={{ marginTop: 12, marginBottom: 0 }}>
          You&rsquo;re on a test deployment — names here carry no value.
        </p>
      )}
    </div>
  );
}
