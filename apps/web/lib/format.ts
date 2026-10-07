/** Both AUSD and USDC are 6 decimals on Monad — verified live, see test/Fork.t.sol. */
export const DOLLAR_DECIMALS = 6;

const UNITS = 10n ** BigInt(DOLLAR_DECIMALS);

/** Formats a 6-decimal integer amount as dollars, e.g. 1234567n -> "1.234567". */
export function formatDollars(amount: bigint, maxFraction = 4): string {
  const negative = amount < 0n;
  const abs = negative ? -amount : amount;
  const whole = abs / UNITS;
  const frac = abs % UNITS;
  const fracStr = frac.toString().padStart(DOLLAR_DECIMALS, "0").slice(0, maxFraction);
  const trimmed = fracStr.replace(/0+$/, "");
  const body = trimmed ? `${whole}.${trimmed}` : whole.toString();
  return negative ? `-${body}` : body;
}

/** Parses a dollar string into 6-decimal units. Returns null on bad input. */
export function parseDollars(input: string): bigint | null {
  const cleaned = input.trim().replace(/,/g, "");
  if (!/^\d*\.?\d*$/.test(cleaned) || cleaned === "" || cleaned === ".") return null;
  const [whole = "0", frac = ""] = cleaned.split(".");
  const fracPadded = frac.slice(0, DOLLAR_DECIMALS).padEnd(DOLLAR_DECIMALS, "0");
  const units = BigInt(whole || "0") * UNITS + BigInt(fracPadded || "0");
  return units;
}

export function shortAddress(a: string): string {
  return a.length > 12 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a;
}

/** A percentage with enough resolution to watch per-second accrual move. */
export function percentOf(part: bigint, whole: bigint): number {
  if (whole === 0n) return 0;
  return Number((part * 10000n) / whole) / 100;
}
