"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPublicClient, createWalletClient, http, type PublicClient, type WalletClient } from "viem";
import { streamVaultAbi, handleRegistryAbi, erc20PermitAbi } from "@/lib/abi";
import {
  activeChain, chainMode, deployment, isDeployed, tokensFor, BLOCK_POLL_MS, GAS_LIMITS,
} from "@/lib/config";
import { formatDollars, parseDollars, percentOf, shortAddress } from "@/lib/format";
import {
  onboard, unlock, storedKeys, hasPasskey, explainMeraError, secureContextProblem, KEY_ROLES,
  type KeyRole, type UnlockedKey,
} from "@/lib/mera";
import { signPermit, permitNonce } from "@/lib/permit";

type StreamRow = {
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

export default function MonPay() {
  const chain = useMemo(activeChain, []);
  const mode = chainMode();
  const tokens = useMemo(() => tokensFor(chain.id), [chain.id]);
  const primary = tokens.find((t) => t.primary) ?? tokens[0];

  const publicClient = useMemo(
    () => createPublicClient({ chain, transport: http("/api/rpc") }) as PublicClient,
    [chain],
  );

  const [ready, setReady] = useState(false);
  const [blockNumber, setBlockNumber] = useState<bigint | undefined>();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  // keys
  const [keys, setKeys] = useState<{ role: KeyRole; address: string }[]>([]);
  const [unlocked, setUnlocked] = useState<UnlockedKey | null>(null);
  const [handle, setHandle] = useState("");
  const [registeredHandle, setRegisteredHandle] = useState<string | null>(null);

  // pay form
  const [payTo, setPayTo] = useState("");
  const [amount, setAmount] = useState("100");
  const [seconds, setSeconds] = useState("60");

  // streams
  const [rows, setRows] = useState<StreamRow[]>([]);
  const [selected, setSelected] = useState<bigint | null>(null);
  const [accrued, setAccrued] = useState<bigint | undefined>();

  const walletClientRef = useRef<WalletClient | null>(null);

  const flash = (m: string) => { setNotice(m); setError(null); };
  const fail = (e: unknown) => { setError(explainMeraError(e)); setBusy(null); };

  // --- boot: reach the chain, refresh stored keys -------------------------
  useEffect(() => {
    setKeys(storedKeys());
    const problem = secureContextProblem();
    if (problem) setError(problem);
    let cancelled = false;
    (async () => {
      try {
        const bn = await publicClient.getBlockNumber();
        if (!cancelled) { setBlockNumber(bn); setReady(true); }
      } catch (e) {
        if (!cancelled) fail(e);
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [publicClient]);

  // --- follow the chain at Monad's real block cadence ---------------------
  useEffect(() => {
    if (!ready) return;
    const t = setInterval(async () => {
      try { setBlockNumber(await publicClient.getBlockNumber()); } catch { /* transient */ }
    }, BLOCK_POLL_MS);
    return () => clearInterval(t);
  }, [ready, publicClient]);

  // --- when an owner key is unlocked, build the wallet client -------------
  useEffect(() => {
    if (!unlocked) { walletClientRef.current = null; return; }
    walletClientRef.current = createWalletClient({
      account: unlocked.account,
      chain,
      transport: http("/api/rpc"),
    }) as WalletClient;
    return () => { unlocked.end(); };
  }, [unlocked, chain]);

  const doUnlock = useCallback(async (role: KeyRole) => {
    setBusy(`unlock-${role}`);
    try {
      const k = await unlock(role);
      setUnlocked(k);
      flash(`${role} key unlocked. Signing from here needs no further passkey prompt.`);
    } catch (e) { fail(e); } finally { setBusy(null); }
  }, []);

  const doOnboard = useCallback(async () => {
    setBusy("onboard");
    try {
      const created = await onboard(handle.trim() || "monpay-user");
      setKeys(storedKeys());
      flash(`Passkey created. Three keys under one passkey — owner ${shortAddress(created.owner)}, session ${shortAddress(created.session)}, receiving ${shortAddress(created.receiving)}.`);
    } catch (e) { fail(e); } finally { setBusy(null); }
  }, [handle]);

  // --- read our own streams (live state; Monad nodes don't serve history) --
  const refreshStreams = useCallback(async () => {
    if (!isDeployed || !deployment.streamVault) return;
    try {
      const next = await publicClient.readContract({
        address: deployment.streamVault, abi: streamVaultAbi, functionName: "nextId",
      });
      const out: StreamRow[] = [];
      for (let i = Number(next) - 1; i >= 0 && out.length < 12; i--) {
        const s = await publicClient.readContract({
          address: deployment.streamVault, abi: streamVaultAbi, functionName: "streams",
          args: [BigInt(i)],
        }) as readonly [string, string, string, bigint, bigint, bigint, bigint, bigint, bigint, bigint, boolean, number];
        out.push({
          id: BigInt(i), sender: s[0], recipient: s[1], token: s[2], amount: s[3],
          withdrawn: s[4], start: s[5], end: s[6], pausedUntil: s[8], cancelled: s[10],
        });
      }
      setRows(out);
      if (out.length && selected === null) setSelected(out[0].id);
    } catch (e) { setError(explainMeraError(e)); }
  }, [publicClient, selected]);

  useEffect(() => { if (ready) void refreshStreams(); }, [ready, refreshStreams]);

  // --- poll accrued() for the selected stream every block -----------------
  useEffect(() => {
    if (!ready || selected === null || !deployment.streamVault) return;
    let live = true;
    const tick = async () => {
      try {
        const a = await publicClient.readContract({
          address: deployment.streamVault!, abi: streamVaultAbi, functionName: "accrued",
          args: [selected],
        });
        if (live) setAccrued(a as bigint);
      } catch { /* transient */ }
    };
    void tick();
    const t = setInterval(tick, BLOCK_POLL_MS);
    return () => { live = false; clearInterval(t); };
  }, [ready, selected, publicClient]);

  const selRow = rows.find((r) => r.id === selected) ?? null;

  // --- actions ------------------------------------------------------------
  const send = async (label: string, fn: () => Promise<`0x${string}`>) => {
    setBusy(label);
    try {
      const hash = await fn();
      await publicClient.waitForTransactionReceipt({ hash });
      flash(`${label} confirmed — ${hash.slice(0, 10)}…`);
      await refreshStreams();
    } catch (e) { fail(e); } finally { setBusy(null); }
  };

  const registerHandle = () =>
    send("Register handle", async () => {
      const wc = walletClientRef.current;
      if (!wc || !unlocked || !deployment.handleRegistry) throw new Error("unlock a key first");
      const receiving = keys.find((k) => k.role === "receiving")?.address as `0x${string}`;
      const h = handle.trim().toLowerCase().replace(/^@/, "");
      return wc.writeContract({
        address: deployment.handleRegistry, abi: handleRegistryAbi, functionName: "registerTo",
        args: [h, receiving ?? unlocked.address], account: unlocked.account, chain, gas: GAS_LIMITS.register,
      });
    }).then(() => setRegisteredHandle(handle.trim().toLowerCase().replace(/^@/, "")));

  /**
   * The gasless payment. The payer signs an EIP-2612 permit; the vault consumes it and
   * pulls the funds. Whoever submits is irrelevant — here it is the same key, but a
   * relayer could do it for someone holding no MON at all.
   */
  const payWithPermit = () =>
    send("Open stream (gasless)", async () => {
      const wc = walletClientRef.current;
      if (!wc || !unlocked || !deployment.streamVault) throw new Error("unlock a key first");
      const units = parseDollars(amount);
      if (!units || units <= 0n) throw new Error("enter an amount");
      const dur = BigInt(Math.max(1, Math.floor(Number(seconds) || 0)));
      const to = payTo.trim().toLowerCase().replace(/^@/, "");
      const recipient = to.startsWith("0x")
        ? (to as `0x${string}`)
        : await publicClient.readContract({
            address: deployment.handleRegistry!, abi: handleRegistryAbi,
            functionName: "resolve", args: [to],
          });
      if (!recipient || recipient === "0x0000000000000000000000000000000000000000") {
        throw new Error(`@${to} is not registered`);
      }
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
      const nonce = await permitNonce(publicClient, primary.address, unlocked.address);
      const p = await signPermit(publicClient, wc, primary.address, primary.symbol, {
        owner: unlocked.address, spender: deployment.streamVault, value: units, nonce, deadline,
      });
      return wc.writeContract({
        address: deployment.streamVault, abi: streamVaultAbi, functionName: "createStreamWithPermit",
        args: [unlocked.address, recipient, primary.address, units, dur, deadline, p.v, p.r, p.s],
        account: unlocked.account, chain, gas: GAS_LIMITS.createStreamWithPermit,
      });
    });

  const withdrawAll = () =>
    send("Withdraw", async () => {
      const wc = walletClientRef.current;
      if (!wc || !unlocked || !deployment.streamVault || selected === null) {
        throw new Error("unlock a key and select a stream first");
      }
      return wc.writeContract({
        address: deployment.streamVault, abi: streamVaultAbi, functionName: "withdrawAll",
        args: [selected], account: unlocked.account, chain, gas: GAS_LIMITS.withdrawAll,
      });
    });

  /** Local-only: MockAUSD has an open mint so the prototype is drivable without a faucet. */
  const mintLocal = () =>
    send("Mint test AUSD", async () => {
      const wc = walletClientRef.current;
      if (!wc || !unlocked) throw new Error("unlock a key first");
      return wc.writeContract({
        address: primary.address,
        abi: [{ type: "function", name: "mint", stateMutability: "nonpayable",
                inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }],
                outputs: [] }] as const,
        functionName: "mint",
        args: [unlocked.address, 10_000n * 10n ** 6n],
        account: unlocked.account, chain, gas: 200_000n,
      });
    });

  const balance = useBalance(primary.address, unlocked?.address, ready);

  return (
    <div className="wrap">
      <header className="top">
        <h1>Mon<span className="dot">Pay</span></h1>
        <div className="small muted">
          {chain.name} · chain {chain.id} ·{" "}
          {blockNumber !== undefined ? <>block <b className="mono">{blockNumber.toString()}</b></> : "connecting…"}
        </div>
      </header>
      <p className="sub">
        Money that arrives from anywhere and streams in by the second, in Agora&apos;s AUSD.
        One passkey, three keys, no seed phrase, no gas.
      </p>

      {!ready && <div className="banner warn">Connecting to Monad through <code>/api/rpc</code>…</div>}
      {error && <div className="banner bad">{error}</div>}
      {notice && <div className="banner ok">{notice}</div>}

      {!isDeployed && (
        <div className="banner warn">
          <b>Contracts are not deployed to this chain yet.</b> Set{" "}
          <code>NEXT_PUBLIC_STREAM_VAULT</code> and <code>NEXT_PUBLIC_HANDLE_REGISTRY</code> in{" "}
          <code>apps/web/.env.local</code> after running <code>script/Deploy.s.sol</code>.
          Until then the passkey layer below is fully usable and the on-chain actions stay
          disabled — this page will not pretend to be live.
        </div>
      )}

      <div className="grid">
        <section className="panel">
          <h2>1 · One passkey, three keys</h2>
          {!hasPasskey() ? (
            <>
              <label>Display name for the passkey</label>
              <input value={handle} onChange={(e) => setHandle(e.target.value)} placeholder="arinza" />
              <div className="row" style={{ marginTop: 10 }}>
                <button onClick={doOnboard} disabled={busy !== null || !ready}>
                  {busy === "onboard" ? "Waiting for passkey…" : "Create passkey"}
                </button>
              </div>
              <p className="small muted" style={{ marginTop: 10 }}>
                Three separate keys are encrypted under one passkey. The key that can move
                money is not the one left in page memory.
              </p>
            </>
          ) : (
            <div className="keys">
              {KEY_ROLES.map(({ role, label, can }) => {
                const k = keys.find((x) => x.role === role);
                return (
                  <div className="key" key={role}>
                    <div>
                      <div className="role">{label}</div>
                      <div className="can">{can}</div>
                      {k && <div className="mono small muted">{k.address}</div>}
                    </div>
                    <button
                      className="small ghost"
                      disabled={busy !== null || !k}
                      onClick={() => doUnlock(role)}
                    >
                      {unlocked?.role === role ? "unlocked" : busy === `unlock-${role}` ? "…" : "Unlock"}
                    </button>
                  </div>
                );
              })}
            </div>
          )}
        </section>

        <section className="panel">
          <h2>2 · Your handle</h2>
          <label>Claim <code>@handle</code> so people can pay you without a hex address</label>
          <div className="row">
            <input
              className="mono" value={handle} placeholder="arinza"
              onChange={(e) => setHandle(e.target.value.replace(/^@/, ""))}
            />
            <button onClick={registerHandle} disabled={!isDeployed || !unlocked || busy !== null}>
              Register
            </button>
          </div>
          {registeredHandle && (
            <p className="small muted" style={{ marginTop: 10 }}>
              <code>@{registeredHandle}</code> resolves to your receiving key. Share that, not an address.
            </p>
          )}
          {unlocked && (
            <p className="small muted" style={{ marginTop: 10 }}>
              {primary.symbol} balance: <b className="mono">{balance === null ? "…" : formatDollars(balance)}</b>
              {mode === "local" && (
                <>
                  {" "}
                  <button className="small ghost" disabled={busy !== null} onClick={mintLocal}>
                    mint test funds
                  </button>
                  <br />
                  <span className="small">
                    Local anvil only — <code>MockAUSD.mint</code> is open so the prototype can be
                    driven end to end. The real AUSD is a permissioned-mint proxy and has no
                    public faucet.
                  </span>
                </>
              )}
            </p>
          )}
        </section>
      </div>

      <section className="panel">
        <h2>3 · Pay someone — signed, not sent</h2>
        <div className="grid">
          <div>
            <label>Pay to (@handle or 0x address)</label>
            <input className="mono" value={payTo} onChange={(e) => setPayTo(e.target.value)} placeholder="@arinza" />
          </div>
          <div>
            <label>Amount ({primary.symbol})</label>
            <input className="mono" value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
          </div>
          <div>
            <label>Stream over (seconds)</label>
            <input className="mono" value={seconds} onChange={(e) => setSeconds(e.target.value)} inputMode="numeric" />
          </div>
        </div>
        <div className="row" style={{ marginTop: 12 }}>
          <button onClick={payWithPermit} disabled={!isDeployed || !unlocked || busy !== null}>
            {busy === "Open stream (gasless)" ? "Signing…" : "Sign & open stream"}
          </button>
          <span className="small muted">
            Token: <b>{primary.symbol}</b> {shortAddress(primary.address)} · the payer signs an
            EIP-2612 permit and never sends a transaction.
          </span>
        </div>
      </section>

      <section className="panel">
        <h2>4 · Streaming live</h2>
        {rows.length === 0 ? (
          <p className="small muted">No streams yet.</p>
        ) : (
          <>
            <table className="streams">
              <thead>
                <tr><th>id</th><th>recipient</th><th>amount</th><th>state</th><th /></tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const paused = r.pausedUntil > BigInt(Math.floor(Date.now() / 1000));
                  const done = r.cancelled || r.withdrawn >= r.amount;
                  return (
                    <tr key={r.id.toString()} onClick={() => setSelected(r.id)} style={{ cursor: "pointer" }}>
                      <td>#{r.id.toString()}</td>
                      <td>{shortAddress(r.recipient)}</td>
                      <td>{formatDollars(r.amount, 2)}</td>
                      <td>
                        <span className={`pill ${r.cancelled ? "done" : paused ? "paused" : done ? "done" : "live"}`}>
                          {r.cancelled ? "cancelled" : paused ? "paused" : done ? "complete" : "streaming"}
                        </span>
                      </td>
                      <td>{selected === r.id ? "◂" : ""}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>

            {selRow && (
              <div style={{ marginTop: 18 }}>
                <div className="big">
                  {accrued === undefined ? "—" : formatDollars(accrued)}
                  <span className="unit">{primary.symbol} accrued</span>
                </div>
                <div className="bar">
                  <i style={{ width: `${accrued === undefined ? 0 : percentOf(accrued, selRow.amount)}%` }} />
                </div>
                <div className="stats">
                  <span>principal <b>{formatDollars(selRow.amount, 2)}</b></span>
                  <span>withdrawn <b>{formatDollars(selRow.withdrawn, 2)}</b></span>
                  <span>
                    {accrued === undefined ? "" : <>progress <b>{percentOf(accrued, selRow.amount).toFixed(2)}%</b></>}
                  </span>
                  <span>polling every <b>{BLOCK_POLL_MS}ms</b></span>
                </div>
                <div className="row" style={{ marginTop: 14 }}>
                  <button onClick={withdrawAll} disabled={!isDeployed || !unlocked || busy !== null}>
                    Withdraw accrued
                  </button>
                  <span className="small muted">
                    Only the recipient can withdraw. On Monad this is worth doing every block.
                  </span>
                </div>
              </div>
            )}
          </>
        )}
      </section>

      <footer>
        Running against <b>{chain.name}</b> ({mode}) · {tokens.map((t) => `${t.symbol} ${shortAddress(t.address)}`).join(" · ")}
        <br />
        Contracts: StreamVault{" "}
        <span className="mono">{deployment.streamVault ? shortAddress(deployment.streamVault) : "not set"}</span>{" "}
        · HandleRegistry{" "}
        <span className="mono">{deployment.handleRegistry ? shortAddress(deployment.handleRegistry) : "not set"}</span>
        <br />
        Chain reads go through <code>/api/rpc</code>. Monad caps <code>eth_getLogs</code> at a 100-block
        range and full nodes do not serve arbitrary historic state, so this UI reads live state
        rather than reconstructing history.
      </footer>
    </div>
  );
}

/** Polls a token balance while an address is unlocked. */
function useBalance(token: `0x${string}`, owner: string | undefined, ready: boolean) {
  const [bal, setBal] = useState<bigint | null>(null);
  const chain = useMemo(activeChain, []);
  const publicClient = useMemo(
    () => createPublicClient({ chain, transport: http("/api/rpc") }) as PublicClient,
    [chain],
  );
  useEffect(() => {
    if (!ready || !owner) { setBal(null); return; }
    let live = true;
    const tick = async () => {
      try {
        const b = await publicClient.readContract({
          address: token, abi: erc20PermitAbi, functionName: "balanceOf",
          args: [owner as `0x${string}`],
        });
        if (live) setBal(b as bigint);
      } catch { /* transient */ }
    };
    void tick();
    const t = setInterval(tick, BLOCK_POLL_MS * 4);
    return () => { live = false; clearInterval(t); };
  }, [ready, owner, token, publicClient]);
  return bal;
}
