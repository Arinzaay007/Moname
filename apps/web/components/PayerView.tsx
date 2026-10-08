"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  type PublicClient,
  type WalletClient,
} from "viem";
import { erc20PermitAbi } from "@/lib/abi";
import { activeChain, chainMode, deployment, isDeployed, tokensFor, GAS_LIMITS } from "@/lib/config";
import { formatDollars, parseDollars, shortAddress } from "@/lib/format";
import { normalizeHandle, resolveHandle } from "@/lib/scan";
import { signPermit, permitNonce } from "@/lib/permit";

/**
 * Pay a @handle. No Moname account, no passkey, no onboarding.
 *
 * This is the other half of the gasless claim, and it is the half that was missing.
 * The recipient page lets anyone WATCH a payment with nothing installed; this page lets
 * anyone SEND one with nothing installed either — the only requirement is a browser
 * wallet that holds AUSD, which they already have if they have money to send.
 *
 * The asymmetry is deliberate and it is the product: receiving needs zero setup because
 * a passkey creates your identity, but paying needs no Moname identity at all. The payer
 * signs an EIP-2612 permit, the relay broadcasts it, and the payer never sends a
 * transaction and never holds MON.
 */

declare global {
  interface Window {
    ethereum?: {
      isMetaMask?: boolean;
      request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
      on?: (event: string, handler: (...args: unknown[]) => void) => void;
      removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
    };
  }
}

/** Durations that make sense for streaming. 60s first because it is the demo. */
const PRESETS = [
  { label: "1 min", seconds: 60 },
  { label: "1 hour", seconds: 3600 },
  { label: "1 day", seconds: 86400 },
  { label: "7 days", seconds: 604800 },
  { label: "30 days", seconds: 2592000 },
];

export default function PayerView({ rawHandle }: { rawHandle: string }) {
  const chain = useMemo(activeChain, []);
  const mode = chainMode();
  const tokens = useMemo(() => tokensFor(chain.id), [chain.id]);
  const primary = tokens.find((t) => t.primary) ?? tokens[0];
  const handle = normalizeHandle(rawHandle);

  const publicClient = useMemo(
    () => createPublicClient({ chain, transport: http("/api/rpc") }) as PublicClient,
    [chain],
  );

  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const [recipient, setRecipient] = useState<string | null>(null);
  const [resolveError, setResolveError] = useState<string | null>(null);

  const [hasWallet, setHasWallet] = useState<boolean | null>(null);
  const [payer, setPayer] = useState<string | null>(null);
  const [walletChainId, setWalletChainId] = useState<number | null>(null);
  const [balance, setBalance] = useState<bigint | null>(null);
  const [relayUp, setRelayUp] = useState<boolean | null>(null);

  const [amount, setAmount] = useState("100");
  const [seconds, setSeconds] = useState("3600");
  const [result, setResult] = useState<{ hash: string; gasUsed: string; gasDeclared: string } | null>(null);

  const units = parseDollars(amount);
  const duration = Math.max(1, Math.floor(Number(seconds) || 0));
  const perSecond = units && duration > 0 ? units / BigInt(duration) : 0n;

  // --- boot -----------------------------------------------------------------
  useEffect(() => {
    setHasWallet(typeof window !== "undefined" && Boolean(window.ethereum));
    let live = true;
    (async () => {
      try {
        await publicClient.getChainId();
        if (live) setReady(true);
      } catch (e) {
        if (live) setError(e instanceof Error ? e.message : String(e));
      }
      fetch("/api/relay")
        .then((r) => r.json())
        .then((d: { ok?: boolean }) => live && setRelayUp(Boolean(d.ok)))
        .catch(() => live && setRelayUp(false));
    })();
    return () => {
      live = false;
    };
  }, [publicClient]);

  // --- who are we paying ----------------------------------------------------
  useEffect(() => {
    if (!ready || !handle) return;
    let live = true;
    (async () => {
      const r = await resolveHandle(publicClient, handle);
      if (!live) return;
      setRecipient(r.address);
      setResolveError(r.address ? null : (r.error ?? null));
    })();
    return () => {
      live = false;
    };
  }, [ready, handle, publicClient]);

  // --- payer balance, refreshed after connect and after a relay -------------
  const refreshBalance = useCallback(async () => {
    if (!payer || !primary) return;
    try {
      const b = await publicClient.readContract({
        address: primary.address,
        abi: erc20PermitAbi,
        functionName: "balanceOf",
        args: [payer as `0x${string}`],
      });
      setBalance(b as bigint);
    } catch {
      setBalance(null);
    }
  }, [payer, primary, publicClient]);

  useEffect(() => {
    void refreshBalance();
  }, [refreshBalance]);

  // --- connect: ask the injected wallet, do not assume ----------------------
  const connect = async () => {
    if (!window.ethereum) {
      setError("No browser wallet found. This page signs an EIP-2612 permit, which needs one.");
      return;
    }
    setBusy("connect");
    setError(null);
    try {
      // A client with no account can still enumerate and request them.
      const probe = createWalletClient({ transport: custom(window.ethereum) }) as WalletClient;
      const accounts = await probe.requestAddresses();
      const acct = accounts[0];
      if (!acct) throw new Error("The wallet returned no accounts.");

      const wc = createWalletClient({
        account: acct,
        chain,
        transport: custom(window.ethereum),
      }) as WalletClient;
      const cid = await wc.getChainId();

      setPayer(acct);
      setWalletChainId(cid);
      if (cid !== chain.id) {
        setError(
          `Your wallet is on chain ${cid} but ${chain.name} is chain ${chain.id}. Switch networks in your wallet, then connect again.`,
        );
      }
    } catch (e) {
      // A rejected connect prompt is normal, not an error worth alarming anyone about.
      const msg = e instanceof Error ? e.message : String(e);
      if (/reject|denied|user/i.test(msg)) setNotice("Connect request declined.");
      else setError(msg);
    } finally {
      setBusy(null);
    }
  };

  // --- sign the permit and hand it to the relay -----------------------------
  const pay = async () => {
    if (!window.ethereum || !payer || !recipient || !primary || !deployment.streamVault) return;
    setBusy("pay");
    setError(null);
    setResult(null);
    try {
      if (!units || units <= 0n) throw new Error("Enter an amount greater than zero.");
      if (balance !== null && units > balance) {
        throw new Error(
          `You hold ${formatDollars(balance)} ${primary.symbol} but are trying to stream ${formatDollars(units)}.`,
        );
      }

      const wc = createWalletClient({
        account: payer as `0x${string}`,
        chain,
        transport: custom(window.ethereum),
      }) as WalletClient;

      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
      const nonce = await permitNonce(publicClient, primary.address, payer as `0x${string}`);
      // The signature is the whole authorisation: it binds owner, spender, value and
      // deadline, so the relay cannot alter what it broadcasts.
      const p = await signPermit(publicClient, wc, primary.address, primary.symbol, {
        owner: payer as `0x${string}`,
        spender: deployment.streamVault,
        value: units,
        nonce,
        deadline,
      });

      const res = await fetch("/api/relay", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          payer,
          recipient,
          token: primary.address,
          amount: units.toString(),
          duration: String(duration),
          deadline: deadline.toString(),
          v: String(p.v),
          r: p.r,
          s: p.s,
        }),
      });
      const data = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        hash?: string;
        gasUsed?: string;
        gasDeclared?: string;
        error?: string;
      };

      if (!res.ok || !data.ok || !data.hash) {
        // 503 means the relay is not configured. Rather than dead-end the payer, offer
        // the fallback the contract already allows: createStreamWithPermit is
        // permissionless, so they may broadcast it themselves — but that costs MON, and
        // we say so instead of quietly charging them.
        if (res.status === 503) {
          setNotice(
            "The relay is not configured, so nobody can submit this for free. You can broadcast " +
              "the permit yourself, but that means paying gas in MON.",
          );
          return;
        }
        throw new Error(data.error ?? `Relay rejected the permit (HTTP ${res.status}).`);
      }

      setResult({ hash: data.hash, gasUsed: data.gasUsed ?? "?", gasDeclared: data.gasDeclared ?? "?" });
      setNotice(
        `Streaming to @${handle}. You signed and sent no transaction — the relay did, and paid the gas.`,
      );
      await refreshBalance();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setError(/reject|denied|user/i.test(msg) ? "Signature request declined." : msg);
    } finally {
      setBusy(null);
    }
  };

  /** Local-only: MockAUSD has an open mint so the prototype is drivable without a faucet. */
  const mintLocal = async () => {
    if (!window.ethereum || !payer || !primary) return;
    setBusy("mint");
    try {
      const wc = createWalletClient({
        account: payer as `0x${string}`,
        chain,
        transport: custom(window.ethereum),
      }) as WalletClient;
      const hash = await wc.writeContract({
        address: primary.address,
        abi: [
          {
            type: "function",
            name: "mint",
            stateMutability: "nonpayable",
            inputs: [
              { name: "to", type: "address" },
              { name: "amount", type: "uint256" },
            ],
            outputs: [],
          },
        ] as const,
        functionName: "mint",
        args: [payer as `0x${string}`, 10_000n * 10n ** 6n],
        // The `as WalletClient` cast erases chain and account from the type, so both
        // must be passed explicitly on every write.
        account: payer as `0x${string}`,
        chain,
        gas: GAS_LIMITS.createStream,
      });
      await publicClient.waitForTransactionReceipt({ hash });
      setNotice("Minted 10,000 local test AUSD to your wallet.");
      await refreshBalance();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const insufficient = balance !== null && units !== null && units > balance;
  const canPay =
    ready &&
    Boolean(recipient) &&
    Boolean(payer) &&
    walletChainId === chain.id &&
    units !== null &&
    units > 0n &&
    !insufficient &&
    busy === null;

  return (
    <main className="wrap">
      <div className="row" style={{ justifyContent: "space-between", alignItems: "center" }}>
        <Link href="/" className="pill" style={{ textDecoration: "none" }}>
          ← Moname
        </Link>
        <span className="pill">
          {mode === "local" ? "local anvil · chain 10143" : mode === "testnet" ? "Monad testnet · 10143" : "Monad mainnet · 143"}
        </span>
      </div>

      <div className="panel" style={{ marginTop: 16 }}>
        <div className="sub">Pay someone — no Moname account needed</div>
        <h1 className="big" style={{ margin: "6px 0 2px" }}>
          {handle ? `Pay @${handle}` : "invalid handle"}
        </h1>
        <div className="mono muted small">
          {recipient
            ? `they receive at ${recipient}`
            : (resolveError ?? "resolving…")}
        </div>
      </div>

      {!isDeployed && (
        <div className="banner" style={{ marginTop: 16 }}>
          Moname is not deployed to this chain yet, so there is nothing to pay. This page will
          not pretend otherwise.
        </div>
      )}
      {error && <div className="banner" style={{ marginTop: 16 }}>{error}</div>}
      {notice && (
        <div className="banner" style={{ marginTop: 16, borderColor: "#2f6f4f" }}>
          {notice}
        </div>
      )}

      {isDeployed && recipient && (
        <>
          {/* Step 1: who is paying */}
          <div className="panel" style={{ marginTop: 16 }}>
            <div className="sub">1 · Your wallet</div>
            {!payer ? (
              <>
                <div className="muted" style={{ marginTop: 6 }}>
                  You need a browser wallet holding <strong>{primary?.symbol ?? "AUSD"}</strong>. That is the
                  only requirement — no Moname account, no passkey, nothing to sign up for. You
                  will be asked to <em>sign</em> a permit, not to send a transaction.
                </div>
                {hasWallet === false && (
                  <div className="small" style={{ marginTop: 8, color: "#fbbf24" }}>
                    No injected wallet was found in this browser. Install one, or open this page
                    in a browser that has one.
                  </div>
                )}
                <button
                  className="pill"
                  style={{ marginTop: 10, cursor: hasWallet ? "pointer" : "not-allowed" }}
                  disabled={!hasWallet || busy !== null}
                  onClick={() => void connect()}
                >
                  {busy === "connect" ? "waiting for wallet…" : "Connect wallet"}
                </button>
              </>
            ) : (
              <>
                <div className="row" style={{ marginTop: 6 }}>
                  <span className="mono small">{payer}</span>
                  <span style={{ flex: 1 }} />
                  <button className="pill" style={{ cursor: "pointer" }} onClick={() => { setPayer(null); setBalance(null); setWalletChainId(null); }}>
                    disconnect
                  </button>
                </div>
                <div className="small muted" style={{ marginTop: 6 }}>
                  {primary?.symbol ?? "AUSD"} balance:{" "}
                  <b className="mono">{balance === null ? "…" : formatDollars(balance)}</b>
                  {walletChainId !== null && walletChainId !== chain.id && (
                    <span style={{ color: "#f87171" }}>
                      {" "}· wallet is on chain {walletChainId}, needs {chain.id}
                    </span>
                  )}
                  {mode === "local" && (
                    <>
                      {" "}
                      <button className="small ghost" disabled={busy !== null} onClick={() => void mintLocal()}>
                        {busy === "mint" ? "minting…" : "mint test funds"}
                      </button>
                      <span className="muted"> (local anvil only)</span>
                    </>
                  )}
                </div>
              </>
            )}
          </div>

          {/* Step 2: terms */}
          <div className="panel" style={{ marginTop: 16 }}>
            <div className="sub">2 · How much, and over how long</div>
            <div className="grid" style={{ marginTop: 8 }}>
              <div>
                <label>Amount ({primary?.symbol ?? "AUSD"})</label>
                <input
                  className="mono"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  inputMode="decimal"
                />
              </div>
              <div>
                <label>Stream over (seconds)</label>
                <input
                  className="mono"
                  value={seconds}
                  onChange={(e) => setSeconds(e.target.value)}
                  inputMode="numeric"
                />
              </div>
            </div>
            <div className="row" style={{ marginTop: 8, gap: 6 }}>
              {PRESETS.map((p) => (
                <button
                  key={p.seconds}
                  className="pill"
                  style={{ cursor: "pointer", opacity: duration === p.seconds ? 1 : 0.6 }}
                  onClick={() => setSeconds(String(p.seconds))}
                >
                  {p.label}
                </button>
              ))}
            </div>
            {units !== null && units > 0n && duration > 0 && (
              <div className="small muted" style={{ marginTop: 10 }}>
                They receive <b className="mono">{formatDollars(perSecond)}</b> {primary?.symbol} per second,
                for {duration.toLocaleString()} seconds — one Monad block is 300 ms, so the balance
                on their page updates several times a second.
                {insufficient && (
                  <span style={{ color: "#f87171" }}>
                    {" "}You only hold {formatDollars(balance ?? 0n)}.
                  </span>
                )}
              </div>
            )}
          </div>

          {/* Step 3: sign */}
          <div className="panel" style={{ marginTop: 16 }}>
            <div className="sub">3 · Sign — you are not sending a transaction</div>
            <div className="muted" style={{ marginTop: 6 }}>
              This asks your wallet for an <strong>EIP-2612 permit</strong> signature. It is a
              signature, not a transaction: you approve exactly {units !== null ? formatDollars(units) : "0"}{" "}
              {primary?.symbol} for the vault to pull once, and it expires in 10 minutes. You pay no
              gas and hold no MON.
              {relayUp === false && (
                <span style={{ color: "#fbbf24" }}>
                  {" "}The relay is currently down, so you would have to broadcast the permit yourself
                  and pay gas in MON.
                </span>
              )}
            </div>
            <button
              style={{ marginTop: 12, cursor: canPay ? "pointer" : "not-allowed" }}
              disabled={!canPay}
              onClick={() => void pay()}
            >
              {busy === "pay" ? "waiting for signature…" : `Sign & start streaming`}
            </button>
            {!canPay && !busy && (
              <div className="small muted" style={{ marginTop: 8 }}>
                {!payer
                  ? "Connect a wallet first."
                  : walletChainId !== chain.id
                    ? `Switch your wallet to chain ${chain.id}.`
                    : insufficient
                      ? "Amount exceeds your balance."
                      : units === null || units <= 0n
                        ? "Enter a valid amount."
                        : ""}
              </div>
            )}
          </div>

          {result && (
            <div className="panel" style={{ marginTop: 16, borderColor: "#2f6f4f" }}>
              <div className="sub">Streaming</div>
              <div className="mono small" style={{ marginTop: 6 }}>
                tx {result.hash}
              </div>
              <div className="small muted" style={{ marginTop: 6 }}>
                Declared {Number(result.gasDeclared).toLocaleString()} gas, used{" "}
                {Number(result.gasUsed).toLocaleString()} — paid by the relayer, not you. Your
                transaction count did not move.
              </div>
              <Link href={`/h/@${handle}`} className="pill" style={{ marginTop: 10, display: "inline-block", textDecoration: "none" }}>
                watch it stream to @{handle} ↗
              </Link>
            </div>
          )}

          <div className="panel" style={{ marginTop: 16 }}>
            <div className="sub">What you are agreeing to</div>
            <div className="small muted" style={{ marginTop: 6 }}>
              The full {units !== null ? formatDollars(units) : "0"} {primary?.symbol} leaves your wallet
              immediately and sits in the StreamVault contract. It is then released to{" "}
              <code>@{handle}</code> over {duration.toLocaleString()} seconds. You can cancel at any
              point and the unaccrued remainder comes straight back to you; whatever has already
              accrued is theirs, because they earned it. A pause you set is bounded by its own
              terms — accrual restarts on its own even if you never resume it, so a forgotten
              pause cannot destroy their income.
            </div>
          </div>
        </>
      )}

      <div className="panel" style={{ marginTop: 16 }}>
        <div className="sub">Recipient</div>
        <div className="small muted" style={{ marginTop: 6 }}>
          Receiving needs no wallet and no account at all.{" "}
          <Link href={`/h/@${handle ?? ""}`}>@{handle ?? "…"}</Link> has a public page where anyone
          can watch their payments arrive — which is also where a sender finds this page.
        </div>
      </div>
    </main>
  );
}
