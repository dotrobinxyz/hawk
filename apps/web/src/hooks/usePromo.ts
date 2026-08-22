import { useReadContract } from "wagmi";
import { hawkPriceOracleAbi } from "hawk-names";
import { ADDRESSES } from "../config";

/**
 * Live launch-promo state, read from the oracle's immutable `promoEnd` —
 * the banner appears while the promo runs and disappears on its own the
 * second it ends, no redeploy needed. promoEnd of 0 means no promo.
 */
export function usePromo() {
  const { data: promoEnd } = useReadContract({
    address: ADDRESSES.priceOracle,
    abi: hawkPriceOracleAbi,
    functionName: "promoEnd",
  });
  const end = promoEnd !== undefined ? Number(promoEnd) : 0;
  const active = end > 0 && Date.now() / 1000 < end;
  const endsLabel = active
    ? new Date(end * 1000)
        .toLocaleDateString("en-US", { month: "short", day: "numeric" })
        .toLowerCase()
    : "";
  return { active, endsLabel };
}
