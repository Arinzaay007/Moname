import { NextResponse } from "next/server";

/**
 * JSON-RPC proxy to Monad.
 *
 * Two reasons this exists rather than calling the public RPC from the browser:
 *   1. Public RPC CORS behaviour is not something to bet a demo on.
 *   2. The preview host differs from localhost, so the browser must use relative URLs
 *      and let the server reach the chain.
 *
 * Read-only by default. Transactions are forwarded too, because the gasless flow needs
 * eth_sendRawTransaction — but the signing happens in the browser via the passkey session,
 * so this proxy never sees a private key. It is a dumb byte pipe.
 */
const UPSTREAM =
  process.env.MONAD_RPC_URL ??
  (process.env.NEXT_PUBLIC_CHAIN === "testnet"
    ? "https://testnet-rpc.monad.xyz"
    : "https://rpc.monad.xyz");

// Monad full nodes do not serve arbitrary historic state, and eth_getLogs is capped at a
// 100-block range. Both are documented Monad limits, not bugs here — the UI avoids
// historical queries and reads live state instead.
const ALLOWED = new Set([
  "eth_chainId",
  "eth_blockNumber",
  "eth_getBlockByNumber",
  "eth_call",
  "eth_estimateGas",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_feeHistory",
  "eth_getBalance",
  "eth_getTransactionCount",
  "eth_getCode",
  "eth_getTransactionReceipt",
  "eth_getTransactionByHash",
  "eth_sendRawTransaction",
  "net_version",
]);

export async function POST(req: Request) {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  const calls = Array.isArray(body) ? body : [body];
  for (const call of calls) {
    const method = (call as { method?: unknown })?.method;
    if (typeof method !== "string" || !ALLOWED.has(method)) {
      return NextResponse.json(
        { jsonrpc: "2.0", id: (call as { id?: number })?.id ?? null, error: { code: -32601, message: `method not allowed: ${String(method)}` } },
        { status: 400 },
      );
    }
  }

  try {
    const upstream = await fetch(UPSTREAM, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      cache: "no-store",
    });
    const json = await upstream.json();
    return NextResponse.json(json, { status: upstream.status });
  } catch (e) {
    return NextResponse.json(
      { jsonrpc: "2.0", id: null, error: { code: -32603, message: e instanceof Error ? e.message : "upstream failure" } },
      { status: 502 },
    );
  }
}
