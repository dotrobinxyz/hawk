/** Reserved lock — flank blue, from the Brand Sheet band-chip states. */
export function LockIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden focusable="false">
      <path
        d="M4 5.5 V4 a2 2 0 0 1 4 0 V5.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
      />
      <rect x="2.5" y="5.5" width="7" height="5.5" rx="1.2" fill="currentColor" />
    </svg>
  );
}

/** Small check — used on the "primary name" chip. */
export function CheckIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden focusable="false">
      <path
        d="M2.5 6.5 L5 9 L9.5 3.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
