type MarkProps = {
  className?: string;
};

/** The Maat mark: two offset solid peaks — an "M" that also reads as collected things side by side. */
export function MaatMark({ className }: MarkProps) {
  return (
    <svg viewBox="0 0 100 100" className={className} fill="currentColor" aria-hidden="true">
      <path d="M11,80 L28,27 L47,57 L47,80 Z" />
      <path d="M89,80 L69,41 L53,60 L53,80 Z" />
    </svg>
  );
}
