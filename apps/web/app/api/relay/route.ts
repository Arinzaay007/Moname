import { NextResponse } from "next/server";
import {
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  http,
  type PublicClient,
  type WalletClient,
} from "viem";
// viem keeps account helpers in a separate entrypoint; `privateKeyToAccount` is NOT
// exported from the package root in 2.37.
import { privateKeyToAccount } from "viem/accounts";
import { streamVaultAbi } from "@/lib/abi";
import { activeChain, chainMode, deployment, isDeployed, tokensFor } from "@/lib/config";

/**
 * The gasless relay. This is what makes "no gas" literally true rather than aspirational.
 *
 * The payer signs an EIP-2612 permit in the browser. That signature is the whole
 * authorisation: it binds owner, spender, value and deadline, so nobody — not this
 * service, not anyone else — can alter the terms. The payer then hands the signature
 * here and NEVER sends a transaction, so they never need to hold MON.
 *
 * Before this existed the UI signed the permit and then broadcast it from the same
 * account, which meant the payer still needed MON for gas. The signature was real but
 * the gasless claim was not. `createStreamWithPermit` is permissionless by design, so
 * this service is a convenience rather than a gatekeeper: anyone may submit a valid
 * permit themselves, and if this relay is down the product still works.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// ---------------------------------------------------------------------------
// The relayer key. Server-side only — NEXT_PUBLIC_ is deliberately absent so it
// can never be inlined into a client bundle. Unset means the relay refuses
// rather than silently falling back to making the user pay.
// ---------------------------------------------------------------------------
const RAW_KEY = process.env.RELAYER_PRIVATE_KEY;
const key = RAW_KEY && /^0x[0-9a-fA-F]{64}$/.test(RAW_KEY) ? (RAW_KEY as `0x${string}`) : undefined;

const UPSTREAM = process.env.MONAD_RPC_URL ?? "https://rpc.monad.xyz";
const chain = activeChain();

const publicClient = createPublicClient({ chain, transport: http(UPSTREAM) }) as PublicClient;
const relayerAccount = key ? privateKeyToAccount(key) : undefined;
const walletClient: WalletClient | undefined =
  key && relayerAccount
    ? (createWalletClient({ account: relayerAccount, chain, transport: http(UPSTREAM) }) as WalletClient)
    : undefined;

// ---------------------------------------------------------------------------
// Monad charges gas on the DECLARED limit, not gas used:
// `value + gas_bid * gas_limit`. Over-declaring is therefore real money spent for
// nothing, which inverts the usual "add generous headroom" instinct.
//
// createStreamWithPermit has a median of 70,772 and a max of 275,876 (see the gas
// table in README.md). A fixed 400,000 would overpay roughly 5.6x on a typical
// relay. So we estimate and add a modest buffer instead.
// ---------------------------------------------------------------------------
const GAS_BUFFER_NUMERATOR = 115n; // estimate * 1.15
const GAS_FLOOR = 90_000n; // never declare below what the median path needs
const GAS_CEILING = 400_000n; // and never above the observed max plus margin

/**
 * Sends are serialised. viem derives the nonce from `pending`, so two concurrent
 * relays would compute the same nonce and one would be dropped or replaced. A
 * promise chain is enough for a single process.
 *
 * ⚠️ THAT DOES NOT HOLD ON SERVERLESS. Vercel runs each concurrent invocation in
 * its own instance, so this module-level queue serialises within one instance and
 * not across them: two simultaneous relays can still collide on a nonce and one
 * will fail. The failure is safe -- a dropped transaction, never a lost or doubled
 * payment, because the permit's nonce is consumed on chain exactly once -- but it
 * is a real limit at concurrent load. A production relayer needs a nonce manager
 * backed by shared state (Upstash Redis or a database row lock), or a single
 * long-lived process instead of serverless.
 */
let sendQueue: Promise<unknown> = Promise.resolve();
function serialised<T>(fn: () => Promise<T>): Promise<T> {
  const run = sendQueue.then(fn, fn);
  sendQueue = run.catch(() => undefined);
  return run;
}

/**
 * Best-effort per-IP throttle. In-memory, so it does not survive a restart and, on
 * serverless, does not coordinate across instances — the effective limit is
 * RATE_MAX per instance rather than per service. Stated as such rather than
 * dressed up as abuse protection. The real protection is that a permit can only ever
 * move the signer's own funds by the signer's own chosen amount.
 */
const hits = new Map<string, number[]>();
const RATE_WINDOW_MS = 60_000;
const RATE_MAX = 20;

function rateLimited(ip: string): boolean {
  const now = Date.now();
  const recent = (hits.get(ip) ?? []).filter((t) => now - t < RATE_WINDOW_MS);
  recent.push(now);
  hits.set(ip, recent);
  return recent.length > RATE_MAX;
}

const HEX64 = /^0x[0-9a-fA-F]{64}$/;
const ADDR = /^0x[0-9a-fA-F]{40}$/;

function bad(message: string, status = 400) {
  return NextResponse.json({ ok: false, error: message }, { status });
}

export async function POST(req: Request) {
  if (!key || !walletClient || !relayerAccount) {
    return bad(
      "The relay is not configured: RELAYER_PRIVATE_KEY is unset. Set it in the server " +
        "environment (never NEXT_PUBLIC_). Until then, sign and submit the permit yourself " +
        "— createStreamWithPermit is permissionless, so the product still works without us.",
      503,
    );
  }
  if (!isDeployed || !deployment.streamVault) {
    return bad("StreamVault is not deployed on this chain.", 503);
  }

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  if (rateLimited(ip)) return bad("Too many relay requests. Wait a minute.", 429);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return bad("Body must be JSON.");
  }
  const b = body as Record<string, unknown>;

  // --- validate ------------------------------------------------------------
  const str = (k: string) => (typeof b[k] === "string" ? (b[k] as string) : undefined);
  const big = (k: string): bigint | undefined => {
    const v = b[k];
    try {
      if (typeof v === "bigint") return v;
      if (typeof v === "number" && Number.isInteger(v) && v >= 0) return BigInt(v);
      if (typeof v === "string" && /^0x[0-9a-fA-F]+$|^\d+$/.test(v)) return BigInt(v);
    } catch {
      return undefined;
    }
    return undefined;
  };

  const payer = str("payer");
  const recipient = str("recipient");
  const token = str("token");
  const v = str("v");
  const r = str("r");
  const s = str("s");
  const amount = big("amount");
  const duration = big("duration");
  const deadline = big("deadline");

  if (!payer || !ADDR.test(payer)) return bad("payer must be a 0x address.");
  if (!recipient || !ADDR.test(recipient)) return bad("recipient must be a 0x address.");
  if (!token || !ADDR.test(token)) return bad("token must be a 0x address.");
  if (!v || !r || !s || !HEX64.test(r) || !HEX64.test(s)) return bad("v, r, s must be a 65-byte signature.");
  if (amount === undefined || amount <= 0n) return bad("amount must be a positive integer in token units.");
  if (duration === undefined || duration <= 0n) return bad("duration must be a positive number of seconds.");
  if (deadline === undefined) return bad("deadline is required.");

  // Only relay tokens we actually support. Without this the relay is a general-purpose
  // permit broadcaster for any ERC-20, which is a wider blast radius than we need.
  const supported = tokensFor(chain.id).map((t) => t.address.toLowerCase());
  if (!supported.includes(token.toLowerCase())) {
    return bad(`token ${token} is not a supported Moname token on chain ${chain.id}.`);
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  if (deadline <= now) {
    return bad("That permit has already expired. Sign a fresh one with a later deadline.");
  }

  const args = [
    payer as `0x${string}`,
    recipient as `0x${string}`,
    token as `0x${string}`,
    amount as bigint,
    duration as bigint,
    deadline as bigint,
    BigInt(v) as bigint,
    r as `0x${string}`,
    s as `0x${string}`,
  ] as const;

  // --- simulate before spending anyone's MON -------------------------------
  // A reverted relay still costs gas, so we call first. This is the main defence
  // against being used to burn the relayer's balance on garbage.
  const data = encodeFunctionData({
    abi: streamVaultAbi,
    functionName: "createStreamWithPermit",
    args: args as never,
  });

  try {
    await publicClient.call({ to: deployment.streamVault, data });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return bad(`The vault rejected this permit, so nothing was sent and no gas was spent: ${msg}`, 422);
  }

  // --- estimate, then declare tightly --------------------------------------
  let gas: bigint;
  try {
    const est = await publicClient.estimateGas({ to: deployment.streamVault, data });
    gas = (est * GAS_BUFFER_NUMERATOR) / 100n;
    if (gas < GAS_FLOOR) gas = GAS_FLOOR;
    if (gas > GAS_CEILING) gas = GAS_CEILING;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return bad(`Gas estimation failed, so nothing was sent: ${msg}`, 422);
  }

  // --- send, serialised so nonces cannot race ------------------------------
  try {
    const result = await serialised(async () => {
      const hash = await walletClient!.writeContract({
        address: deployment.streamVault!,
        abi: streamVaultAbi,
        functionName: "createStreamWithPermit",
        args: args as never,
        account: relayerAccount!,
        chain,
        gas,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      return { hash, receipt };
    });

    if (result.receipt.status !== "success") {
      return NextResponse.json(
        {
          ok: false,
          error: "The transaction was included but reverted. No gas was refunded — Monad charges the declared limit.",
          hash: result.hash,
          gasDeclared: gas.toString(),
          gasUsed: result.receipt.gasUsed.toString(),
        },
        { status: 500 },
      );
    }

    return NextResponse.json({
      ok: true,
      hash: result.hash,
      blockNumber: result.receipt.blockNumber.toString(),
      gasDeclared: gas.toString(),
      gasUsed: result.receipt.gasUsed.toString(),
      relayer: relayerAccount.address,
      chainMode: chainMode(),
      note:
        "Relayed by Moname. The payer signed and never sent a transaction, so they hold no MON. " +
        "Gas was declared at estimate * 1.15 because Monad charges the declared limit, not gas used.",
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return bad(`Relay failed: ${msg}`, 500);
  }
}

export async function GET() {
  // Health check that never reveals the key.
  return NextResponse.json({
    ok: Boolean(key && walletClient),
    configured: Boolean(key),
    relayer: relayerAccount?.address ?? null,
    streamVault: deployment.streamVault ?? null,
    chainMode: chainMode(),
    chainId: chain.id,
    gasPolicy: {
      buffer: "estimate * 1.15",
      floor: GAS_FLOOR.toString(),
      ceiling: GAS_CEILING.toString(),
      reason: "Monad charges gas on the declared limit, not gas used",
    },
    rateLimit: { windowMs: RATE_WINDOW_MS, max: RATE_MAX, scope: "per IP, in-memory" },
  });
}
