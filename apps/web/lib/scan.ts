import type { PublicClient } from "viem";
import { streamVaultAbi, handleRegistryAbi } from "@/lib/abi";
import { deployment, isDeployed } from "@/lib/config";

/**
 * Reading a recipient's streams on Monad, without an indexer.
 *
 * This is the constraint that shapes the whole read layer, and it is worth being
 * explicit about because it is unusual:
 *
 *   - Monad full nodes do NOT serve arbitrary historic state, so you cannot ask
 *     "what was true at block N" for an old N.
 *   - `eth_getLogs` is capped at a 100-block range. At 300 ms blocks that is
 *     ~30 SECONDS of history. Event scanning is therefore useless for anything
 *     a user would call "my payments".
 *   - There is no global mempool, so you cannot watch pending work either.
 *
 * What does work is reading LIVE current state: `streams(id)` is a plain storage
 * read that is always available, and `nextId` is a monotonic counter. So we walk
 * the counter backwards and keep the rows whose recipient matches. No indexer, no
 * archive node, no event history — just current state.
 *
 * The honest cost: this is O(streams ever created), not O(this recipient's
 * streams). It is bounded below by SCAN_WINDOW and is entirely adequate for a
 * launch and for this demo, but it is NOT the long-term answer. The two real fixes,
 * both recorded in ROADMAP.md, are an on-chain per-recipient index
 * (`mapping(address => uint256[])`) or an Envio HyperSync indexer. We chose not to
 * touch the verified contracts in the final week to add the former — StreamVault is
 * fork-tested against live mainnet and 58 tests pass; that is worth more than a
 * cheaper read.
 */
export const SCAN_WINDOW = 64;
const CONCURRENCY = 16;

/** The 12-field Stream tuple, positionally, as declared in src/StreamVault.sol. */
export type StreamTuple = readonly [
  string, // 0  sender
  string, // 1  recipient
  string, // 2  token
  bigint, // 3  amount
  bigint, // 4  withdrawn
  bigint, // 5  start
  bigint, // 6  end
  bigint, // 7  pausedFrom
  bigint, // 8  pausedUntil
  bigint, // 9  pausedTotal
  boolean, // 10 cancelled
  number, // 11 controllerCount
];

export type StreamRow = {
  id: bigint;
  sender: string;
  recipient: string;
  token: string;
  amount: bigint;
  withdrawn: bigint;
  start: bigint;
  end: bigint;
  pausedUntil: bigint;
  cancelled: boolean;
};

function toRow(id: bigint, s: StreamTuple): StreamRow {
  return {
    id,
    sender: s[0],
    recipient: s[1],
    token: s[2],
    amount: s[3],
    withdrawn: s[4],
    start: s[5],
    end: s[6],
    pausedUntil: s[8],
    cancelled: s[10],
  };
}

async function readStream(client: PublicClient, id: bigint): Promise<StreamRow | null> {
  const vault = deployment.streamVault;
  if (!vault) return null;
  try {
    const s = (await client.readContract({
      address: vault,
      abi: streamVaultAbi,
      functionName: "streams",
      args: [id],
    })) as StreamTuple;
    // An unset slot reads as all-zeroes rather than reverting, so a zero sender
    // means "this id has never been used" — skip it rather than show a ghost.
    if (!s[0] || s[0] === "0x0000000000000000000000000000000000000000") return null;
    return toRow(id, s);
  } catch {
    return null;
  }
}

/**
 * Every stream in the last `window` ids whose recipient is `recipient`.
 * Reads run in bounded parallel batches; each is a free view call, but we cap
 * concurrency so we do not hammer a public RPC or trip a rate limit mid-demo.
 */
export async function streamsForRecipient(
  client: PublicClient,
  recipient: string,
  window = SCAN_WINDOW,
): Promise<{ rows: StreamRow[]; scanned: number; truncated: boolean; nextId: bigint }> {
  if (!isDeployed || !deployment.streamVault) {
    return { rows: [], scanned: 0, truncated: false, nextId: 0n };
  }
  const want = recipient.toLowerCase();
  const nextId = (await client.readContract({
    address: deployment.streamVault,
    abi: streamVaultAbi,
    functionName: "nextId",
  })) as bigint;

  const first = nextId > BigInt(window) ? nextId - BigInt(window) : 0n;
  const ids: bigint[] = [];
  for (let i = nextId - 1n; i >= first; i--) ids.push(i);

  const rows: StreamRow[] = [];
  for (let i = 0; i < ids.length; i += CONCURRENCY) {
    const batch = await Promise.all(ids.slice(i, i + CONCURRENCY).map((id) => readStream(client, id)));
    for (const r of batch) if (r && r.recipient.toLowerCase() === want) rows.push(r);
  }
  return { rows, scanned: ids.length, truncated: first > 0n, nextId };
}

/** `accrued()` for one stream — the ~1.9k-gas read that makes per-block polling free. */
export async function accruedOf(client: PublicClient, id: bigint): Promise<bigint | null> {
  const vault = deployment.streamVault;
  if (!vault) return null;
  try {
    return (await client.readContract({
      address: vault,
      abi: streamVaultAbi,
      functionName: "accrued",
      args: [id],
    })) as bigint;
  } catch {
    return null;
  }
}

/** `withdrawable()` — accrued that has not yet been claimed. */
export async function withdrawableOf(client: PublicClient, id: bigint): Promise<bigint | null> {
  const vault = deployment.streamVault;
  if (!vault) return null;
  try {
    return (await client.readContract({
      address: vault,
      abi: streamVaultAbi,
      functionName: "withdrawable",
      args: [id],
    })) as bigint;
  } catch {
    return null;
  }
}

/** Resolve `@handle` to the address payments land at. Null if unregistered. */
export async function resolveHandle(
  client: PublicClient,
  handle: string,
): Promise<{ address: string | null; error?: string }> {
  const registry = deployment.handleRegistry;
  if (!isDeployed || !registry) return { address: null, error: "HandleRegistry is not deployed." };
  const clean = normalizeHandle(handle);
  if (!clean) return { address: null, error: "That is not a valid handle." };
  try {
    const address = (await client.readContract({
      address: registry,
      abi: handleRegistryAbi,
      functionName: "resolve",
      args: [clean],
    })) as string;
    if (!address || address === "0x0000000000000000000000000000000000000000") {
      return { address: null, error: `@${clean} is not registered.` };
    }
    return { address };
  } catch (e) {
    // resolve() reverts HandleNotRegistered() rather than returning zero.
    const msg = e instanceof Error ? e.message : String(e);
    if (/HandleNotRegistered/i.test(msg)) return { address: null, error: `@${clean} is not registered.` };
    return { address: null, error: msg };
  }
}

/**
 * Handles are lowercase a-z0-9_ and at most 24 bytes — the charset HandleRegistry
 * enforces on-chain. We accept a leading `@` because that is how people will type
 * and say it, and lowercase on the way in so a shared link is case-insensitive.
 */
export function normalizeHandle(input: string): string | null {
  const h = input.trim().replace(/^@+/, "").toLowerCase();
  if (!h || h.length > 24 || !/^[a-z0-9_]+$/.test(h)) return null;
  return h;
}

// ---------------------------------------------------------------------------
// Stream state. Derived from live fields plus the clock, never stored — storing
// a status flag is how a contract ends up disagreeing with itself.
// ---------------------------------------------------------------------------

export type StreamPhase =
  | "cancelled"
  | "settled" // fully paid out
  | "paused" // frozen, and the pause has NOT yet expired
  | "pause-expired" // pause expired but nobody has called resume() yet
  | "live"
  | "complete"; // window elapsed; all principal accrued

export const PHASE_LABEL: Record<StreamPhase, string> = {
  cancelled: "Cancelled",
  settled: "Settled",
  paused: "Paused",
  "pause-expired": "Pause expired — accruing again",
  live: "Streaming",
  complete: "Complete",
};

/**
 * `now` is a unix timestamp in seconds, from the chain, not the browser clock —
 * the two can disagree and the contract only ever honours block.timestamp.
 */
export function phaseOf(row: StreamRow, now: bigint): StreamPhase {
  if (row.cancelled) return "cancelled";
  if (row.withdrawn >= row.amount) return "settled";
  if (row.pausedUntil > 0n) {
    // Accrual auto-restarts at pausedUntil whether or not anyone calls resume(),
    // so an expired-but-unsettled pause is NOT frozen. Surfacing that state is the
    // point: it is the guarantee that a forgotten resume cannot destroy income.
    return row.pausedUntil > now ? "paused" : "pause-expired";
  }
  return now >= row.end ? "complete" : "live";
}

export function isActive(phase: StreamPhase): boolean {
  return phase === "live" || phase === "paused" || phase === "pause-expired";
}

/** 0..100, for the progress bar. Uses accrued vs principal, not clock vs window,
 *  so a paused stream visibly stops advancing. */
export function progressOf(accrued: bigint, amount: bigint): number {
  if (amount === 0n) return 0;
  const pct = Number((accrued * 10000n) / amount) / 100;
  return Math.max(0, Math.min(100, pct));
}
