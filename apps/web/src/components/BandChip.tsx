/**
 * Band chip — the brand signature. Every name in the app renders inside one
 * (Brand Sheet §2). Contrast rules are enforced by the CSS variants:
 *   - outline (default): charcoal ink on the buff/light ground
 *   - night: night-filled chip on a light ground; the .hawk suffix turns
 *     green because its immediate ground is now night
 *   - green-outline: for use on a night ground — green border, green suffix
 *   - green: green fill with charcoal ink (green is never text on green)
 */
export type BandVariant = "outline" | "night" | "green-outline" | "green";
export type BandSize = "sm" | "md" | "lg" | "xl";

const sizeClass: Record<BandSize, string> = {
  sm: "sm",
  md: "",
  lg: "lg",
  xl: "xl",
};

/** Accepts a label with or without a trailing ".hawk"; renders the suffix. */
export function BandChip({
  name,
  variant = "outline",
  size = "md",
  title,
}: {
  name: string;
  variant?: BandVariant;
  size?: BandSize;
  title?: string;
}) {
  const label = name.replace(/\.hawk$/i, "");
  const cls = ["band", variant === "outline" ? "" : variant, sizeClass[size]]
    .filter(Boolean)
    .join(" ");

  // For the large hero bands, size the font to the name length so a long
  // name stays on one line and never overflows the card (the mono metric is
  // ~0.6em/char; the numerator is the px budget at a phone's inner width).
  const total = label.length + 6; // + ".hawk"
  const fit =
    size === "xl"
      ? { fontSize: `clamp(16px, min(6vw, ${Math.floor(520 / total)}px), 44px)` }
      : size === "lg"
        ? { fontSize: `clamp(15px, min(5vw, ${Math.floor(410 / total)}px), 34px)` }
        : undefined;

  return (
    <span className={cls} style={fit} title={title ?? `${label}.hawk`}>
      <span>{label}</span>
      <span className="tld">.hawk</span>
    </span>
  );
}
