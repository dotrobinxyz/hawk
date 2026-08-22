import { useState } from "react";
import {
  useAccount,
  useConnect,
  useReadContract,
  useWriteContract,
} from "wagmi";
import { erc20Abi, keccak256, parseAbi, stringToBytes } from "viem";
import { ADDRESSES } from "../config";
import { SALE_ADDRESS, PREMIUM_CONTACT } from "../data/premiumNames";

const saleAbi = parseAbi([
  "function priceOf(uint256 id) view returns (uint256)",
  "function priceInWei(string label) view returns (uint256)",
  "function priceInUSDC(string label) view returns (uint256)",
  "function buyWithETH(string label) payable",
  "function buyWithUSDC(string label)",
]);

/** Buy controls for a sale-held premium name: ETH one-shot, or USDC
 *  approve-then-buy. Falls back to the inquire mailto while the sale
 *  contract is unset. */
export function PremiumBuy({
  label,
  saleAddress,
}: {
  label: string;
  saleAddress?: `0x${string}`;
}) {
  const { address, isConnected } = useAccount();
  const { connectors, connect } = useConnect();
  const { writeContractAsync } = useWriteContract();
  const [busy, setBusy] = useState<"" | "eth" | "usdc">("");
  const [done, setDone] = useState(false);

  const sale = saleAddress ?? (SALE_ADDRESS || undefined);
  const id = BigInt(keccak256(stringToBytes(label)));

  const { data: listPrice, refetch: refetchListed } = useReadContract({
    address: sale,
    abi: saleAbi,
    functionName: "priceOf",
    args: [id],
    query: { enabled: Boolean(sale) },
  });
  const { data: weiPrice } = useReadContract({
    address: sale,
    abi: saleAbi,
    functionName: "priceInWei",
    args: [label],
    query: { enabled: Boolean(sale) && listPrice !== undefined && listPrice > 0n, refetchInterval: 30_000 },
  });
  const { data: usdcPrice } = useReadContract({
    address: sale,
    abi: saleAbi,
    functionName: "priceInUSDC",
    args: [label],
    query: { enabled: Boolean(sale) && listPrice !== undefined && listPrice > 0n },
  });
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: ADDRESSES.usdc,
    abi: erc20Abi,
    functionName: "allowance",
    args: address && sale ? [address, sale] : undefined,
    query: { enabled: Boolean(address && sale) },
  });

  if (!sale) {
    return (
      <a
        className="muted small"
        href={`mailto:${PREMIUM_CONTACT}?subject=${encodeURIComponent(`${label}.hawk`)}`}
      >
        inquire
      </a>
    );
  }
  if (done || listPrice === 0n) {
    return <span className="tag reserved">sold</span>;
  }
  if (!isConnected) {
    return (
      <button
        className="btn small"
        onClick={() => connectors[0] && connect({ connector: connectors[0] })}
      >
        connect to buy
      </button>
    );
  }

  const needsApprove =
    usdcPrice !== undefined &&
    allowance !== undefined &&
    allowance < usdcPrice;

  async function buyEth() {
    if (weiPrice === undefined) return;
    setBusy("eth");
    try {
      await writeContractAsync({
        address: sale as `0x${string}`,
        abi: saleAbi,
        functionName: "buyWithETH",
        args: [label],
        value: (weiPrice * 101n) / 100n, // contract refunds the excess
      });
      setDone(true);
    } finally {
      setBusy("");
      refetchListed();
    }
  }

  async function buyUsdc() {
    if (usdcPrice === undefined) return;
    setBusy("usdc");
    try {
      if (needsApprove) {
        await writeContractAsync({
          address: ADDRESSES.usdc,
          abi: erc20Abi,
          functionName: "approve",
          args: [sale as `0x${string}`, usdcPrice],
        });
        await refetchAllowance();
      } else {
        await writeContractAsync({
          address: sale as `0x${string}`,
          abi: saleAbi,
          functionName: "buyWithUSDC",
          args: [label],
        });
        setDone(true);
      }
    } finally {
      setBusy("");
      refetchListed();
    }
  }

  return (
    <span className="row" style={{ gap: 8 }}>
      <button className="btn small" disabled={busy !== ""} onClick={buyEth}>
        {busy === "eth" ? "…" : "buy · eth"}
      </button>
      <button
        className="btn small secondary"
        disabled={busy !== ""}
        onClick={buyUsdc}
      >
        {busy === "usdc" ? "…" : needsApprove ? "approve usdc" : "buy · usdc"}
      </button>
    </span>
  );
}
