# Moname — complete specification

Everything this project is, as it actually stands in the code. Where a number appears here
it was either measured on-chain with `cast`, read from a forge artifact, or produced by a
passing test — not estimated and not copied from a third-party README.

---

## 1. What it is

Moname makes a cross-border payment **arrive as a stream instead of a lump sum**.

A client in Berlin owes a freelancer in Port Harcourt. Today that money moves as one
transfer that lands days later, costs a percentage of a small amount, and leaves the
freelancer unable to prove income in progress. With Moname the client signs once, the money
lands on Monad as Agora's AUSD, and from that instant it accrues to the freelancer **every
300 milliseconds**. She can withdraw at any moment. She never sees a seed phrase, never
holds gas, and can be paid by `@handle` instead of a 42-character address.

Three separate capabilities, used as three layers of one flow rather than three features:

| Layer | Wedge | What it solves |
|---|---|---|
| money **in** | cross-border | Getting funds onto Monad from any chain, cheaply |
| user **on** | gasless | Nobody needs MON, a seed phrase, or a wallet extension |
| money **out** | streaming | Income is continuous and provable, not net-30 |

**Streaming is the moat.** It is the only layer that answers §9.2's requirement to
"demonstrate why Monad's capabilities are utilized." Per-second accrual is uneconomic on
Ethereum (one withdrawal costs more than a day's accrual), marginal on a ~1 s chain, and
trivial at 300 ms blocks with ~600 ms deterministic finality.

**Target: Monad mainnet, chain 143. Primary token: Agora AUSD.**

---

## 2. The user journeys

### 2.1 Receiving for the first time

1. Open Moname. Tap **Create passkey**. One WebAuthn prompt.
2. That single ceremony creates a passkey and encrypts **three** separate keys under it (owner, session, receiving). No seed phrase is ever generated, shown, or stored.
3. Claim `@arinza`. The handle is registered to the **receiving** key — deliberately not the owner key, so being paid and holding funds are different capabilities.
4. Share `@arinza`. That is the whole onboarding.

### 2.2 Paying someone

1. Unlock the owner key (one passkey prompt; signing afterwards is silent).
2. Enter `@arinza`, an amount, and a duration in seconds.
3. Tap **Sign & open stream**. The app resolves the handle on-chain, reads the token's
   permit nonce, and asks for an **EIP-2612 signature** — not a transaction.
4. `createStreamWithPermit` consumes the signature and pulls exactly that amount.

The payer may hold zero MON. Whoever submits the transaction is irrelevant, because the
signature *is* the authorisation. Our relayer normally submits; anyone may.

### 2.3 Watching money arrive

The recipient's view polls `accrued(id)` every 300 ms and renders a moving number with a
progress bar. This is the demo's centrepiece: a figure that visibly climbs several times a
second is something no other chain can show.

### 2.4 Withdrawing

`withdrawAll` — recipient only. On Monad this is cheap enough (~81k gas) to do every block.
`test_accrual_advancesPerBlock_likeMonad` performs 200 withdrawals at one per 300 ms block
and asserts the recipient is never overpaid by a wei.

### 2.5 Operating a stream without being able to steal it

Unlock the **session** key. It can `pause`, `resume` and `cancel`, and nothing else. It
cannot withdraw and cannot change terms, because on-chain it is a `controllers` entry, not
the sender. A compromised browser session can interrupt a stream; it cannot drain one.

### 2.6 Watching someone else's money arrive — no wallet at all

`/h/@arinza` is the recipient's public page, and the constraint that shapes it is that it
must open with **no wallet, no passkey, no account and no setup**. The person looking at it
is often not the person being paid: a client checking a payment is really flowing, a link
pasted into a chat, a second screen at a demo.

So it is reads-only forever. It resolves the handle on-chain, walks the stream counter
backwards to find streams addressed to that receiving key, and polls `accrued()` for each
active one every 300 ms — so the numbers visibly climb several times a second. Unlocking the
receiving key is required for exactly one thing: withdrawing.

This is the demo's second screen. One browser streams money out; another, with nothing
installed and nothing connected, shows it arriving.

It also refuses to be misleading about its own read model. Monad nodes do not serve arbitrary
historic state and cap `eth_getLogs` at a 100-block range — about **30 seconds** of history at
300 ms blocks — so event scanning cannot answer "show me my payments". The page therefore reads
**live current state** and says so on the page itself, along with the bound: it covers the most
recent `SCAN_WINDOW` (64) streams, and older ones need a per-recipient on-chain index or an
Envio HyperSync indexer. Both are in `ROADMAP.md`. Disclosing the limit beats letting a judge
discover it.
### 2.7 Paying with no Moname account at all

`/pay/@arinza` is the mirror of the recipient page, and it removes the other half of the
onboarding friction.

Before this existed, paying someone required creating a passkey and unlocking the owner key —
which meant a payer had to onboard to Moname just to send money once. That is backwards. The
only thing a payer actually needs is a browser wallet holding AUSD, which they already have if
they have money to send.

So the flow is: connect wallet, enter an amount and a duration, sign one EIP-2612 permit. No
account, no passkey, no Moname identity, no MON, and no transaction sent. The relay broadcasts
it. The page is explicit that a permit is *a signature and not a transaction*, and shows the
per-second rate the recipient will see before the payer commits.

The asymmetry is the product: **receiving** needs zero setup because a passkey creates your
identity; **paying** needs no Moname identity at all.

`tools/test-relay.sh` proves this path against a live deployment using a raw anvil key that has
never touched Moname — the payer's transaction count is asserted to be zero afterwards.

---

## 3. Contracts

### 3.1 `src/StreamVault.sol` — 503 lines, 6,783 bytes runtime (limit 128 KB)

The 12-field record. Field order matters: Monad's MIP-8 warms **128 consecutive storage
slots per page** rather than per slot, so keeping a stream's fields contiguous is why
`accrued()` reads at ~1.9k gas and the UI can afford to poll it every block.

```solidity
struct Stream {
    address sender;             // funds it, can cancel
    address recipient;          // withdraws accrued
    address token;              // AUSD (primary) or USDC, both 6 decimals
    uint128 amount;             // total principal
    uint128 withdrawn;          // already claimed
    uint64  start;              // accrual start
    uint64  end;                // accrual end; shifts right when a pause is settled
    uint64  pausedFrom;         // when the current/last pause began
    uint64  pausedUntil;        // 0 = running; > now = frozen until then
    uint64  pausedTotal;        // cumulative SETTLED paused seconds
    bool    cancelled;
    uint8   controllerCount;
}
```

**Writes**

| Function | Who | What |
|---|---|---|
| `createStream(recipient, token, amount, duration)` | anyone | `transferFrom(msg.sender)`, opens a stream |
| `createStreamWithPermit(payer, recipient, token, amount, duration, deadline, v, r, s)` | **anyone** | Consumes an EIP-2612 signature, pulls from `payer`. The gasless path |
| `createStreamWithControllers(recipient, token, amount, duration, controllers[])` | anyone | As above plus up to **4** delegated controllers |
| `withdraw(id, amount)` | recipient | Claim a specific amount, `nonReentrant` |
| `withdrawAll(id)` | recipient | Claim everything accrued, `nonReentrant` |
| `pause(id, until)` | sender or controller | Freeze accrual from now until `until` |
| `resume(id)` | sender/controller **before** expiry; **anyone after** | Book the paused interval, shift `end` right |
| `cancel(id)` | sender or controller | Pay out accrued to recipient, refund remainder to sender, `nonReentrant` |
| `setController(id, controller, allowed)` | sender only | Add/remove a session key |
| `creditArrival(recipient, token, amount, duration)` | forwarder only | Open a stream on tokens that already landed |
| `setForwarder(address)` | owner | Point the relayer; `address(0)` disables `creditArrival` |

**Reads:** `accrued(id)`, `withdrawable(id)`, `streams(id)`, `nextId()`, `controllers(id, addr)`, `forwarder()`, `owner()`.

**13 custom errors** — `StreamNotFound`, `NotSender`, `NotRecipient`, `NotSenderOrController`, `NotPaused`, `AlreadyCancelled`, `ExceedsWithdrawable`, `ZeroAddress`, `ZeroAmount`, `ZeroDuration`, `TooManyControllers`, `DuplicateController`, `ControllerIsSender`.

**7 events** — `StreamCreated`, `StreamCreatedWithPermit`, `Withdrawn`, `Paused`, `Resumed`, `Cancelled`, `ControllerSet`.

### 3.2 The accrual model, in full

```
span     = end - start                  // wall window; grows when a pause is settled
accruing = span - pausedTotal           // the window that actually pays
reached  = live ? pausedFrom - start    // frozen while a pause is running
                : now - start           // running otherwise
reached -= unsettledPauseInterval       // only once that pause has EXPIRED
reached  = min(reached, accruing)
accrued  = amount * reached / accruing
```

Three properties, each pinned by tests:

- **Principal is conserved.** Over any number of pause/resume cycles the recipient receives
  exactly `amount`, just later in wall-clock terms.
- **Rounding is always down.** `_linear` widens to `uint256` before multiplying, so the
  recipient can never be overpaid. `test_accrual_roundsDown_neverUp`.
- **Settlement timing is irrelevant to the payout curve.** `resume()` moves `end` and
  `pausedTotal` together and the two changes cancel. `test_accrual_isIndependentOfSettlementTiming`
  walks a settled and an unsettled stream across 30 instants and asserts they agree.

### 3.3 The pause decision (the interesting part)

A pause is **bounded by its own terms**. `pause(id, until)` freezes accrual until `until`,
and accrual restarts at `until` *whether or not anyone ever calls `resume()`*.

The alternative — freeze until someone resumes — means a sender who pauses and walks away
has silently destroyed the recipient's income. On a payment rail that is not acceptable, and
it is precisely the kind of failure that would not surface until a real user hit it.

Therefore:

- `resume()` **before** expiry → sender or controller only. Ending a pause early is a decision.
- `resume()` **after** expiry → **permissionless**, so a recipient can always settle an abandoned pause.
- Settlement only makes the `end` shift permanent; it never changes `accrued()`.

### 3.4 Two bugs that were real, and how they were caught

Both are recorded in full because they shaped the design.

**Clamp ordering.** The unsettled pause interval was subtracted *after* clamping to the
window. Once the clock ran past `end` with a pause still unbooked, the clamp had already
consumed the headroom the subtraction needed, so `accrued` stuck at
`(span − pause) / span` **forever** — a recipient permanently capped at 70 % of money that
had fully accrued. Found by driving the *deployed* contract on a local Monad-mode anvil, not
by the unit suite, because no unit test ran a stream past its window with an unsettled pause.
Fixed by subtracting before clamping, then verified against an independent Python model at
eight points spanning the boundary. `test_unsettledPause_afterWindowOverrun_doesNotStickBelowFull`
was confirmed to fail against the reintroduced bug with exactly the predicted `70000000 != 100000000`.

**`creditArrival` double-charging.** The first version called `_create`, which does
`transferFrom`. But `creditArrival` exists for tokens that have *already landed* in the vault
(a bridge fill), so pulling again would charge twice. It now records the stream directly and
checks `balanceOf` sufficiency instead.

### 3.5 `src/HandleRegistry.sol` — 149 lines, 1,927 bytes

`@handle` → address, so nobody has to read a hex string aloud.

- Charset `a-z0-9_`, lowercase only (so handles can be spoken without ambiguity), max **24** bytes.
- `register(handle)` — claim for yourself.
- `registerTo(handle, receiving)` — claim, but point it at a **different** address. This is the receiving key.
- `setReceivingAddress(handle, receiving)` — owner repoints where money lands.
- `transferHandle(handle, to)`, `release(handle)`, `resolve(handle)`, `isRegistered(handle)`.
- 7 errors: `HandleEmpty`, `HandleTooLong`, `HandleInvalidChar(bytes1)`, `HandleTaken`, `HandleNotRegistered`, `NotHandleOwner`, `ZeroAddress`.

---

## 4. Tokens and network — all verified live

Read off-chain with `cast` on 2026-10-07, and re-asserted against live state by `test/Fork.t.sol`.

| Token | Mainnet (143) | Testnet (10143) | Decimals | Permit |
|---|---|---|---|---|
| **AUSD** (Agora) — primary | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` | `0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC` | 6 | EIP-2612 **+** EIP-3009 |
| **USDC** (Circle) — secondary | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` | **not deployed** | 6 | EIP-2612 |

- AUSD mainnet supply at verification: **144,570,251 AUSD**. It is an EIP-1967 proxy; implementation `0xc1e3C7D486d6A92fBE920232E439EeC2cEb112dA`.
- AUSD's codesize is **5937 on both networks** — identical bytecode, so testnet behaviour transfers.
- EIP-3009 confirmed by finding `transferWithAuthorization`'s selector `0xe3ee160e` in AUSD's bytecode.
- **Testnet has no USDC** (both candidate addresses return codesize 0). AUSD is the only dollar stablecoin there, which is a second reason it is primary.
- Both tokens being 6 decimals and permit-capable is why **one deployment serves either** — token choice is configuration, not code. `test_oneVaultServesAUSDandUSDC`.

**Block time is exactly 300 ms**, measured on live mainnet: blocks 111325867…111325887 spanned 6 seconds over 20 blocks. Note viem's own `monadTestnet` definition says 400 ms, which is wrong for mainnet.

**Monad constraints this design works inside:**

| Constraint | Consequence here |
|---|---|
| Gas charged on the **declared limit**, not gas used | The UI sets explicit limits (`GAS_LIMITS`); the relayer must never let an estimate stand |
| `eth_getLogs` capped at a **100-block range** | No historical log scanning; the RPC proxy refuses `eth_getLogs` outright |
| Full nodes do **not** serve arbitrary historic state | The UI reads live state; an indexer (Envio HyperSync) is a post-hackathon item |
| 128 KB contract limit | StreamVault is 6,783 bytes — ample headroom |
| MIP-8 warms 128 slots per page | The 12-field struct is laid out to benefit; `accrued()` ≈ 1.9k gas |
| `secp256r1` precompile at `0x0100` (EIP-7951) | On-chain passkey verification is possible; deferred, see ROADMAP |

---

## 5. Gas, measured under Monad execution

`forge test --network monad --gas-report`

**Read this table with one caveat, because it bit us.** Forge's gas report aggregates
*every* call to a function across the whole suite — including the calls made inside
`vm.expectRevert` tests. For a function whose coverage is mostly negative tests, the median
is therefore a **revert cost**, not a success cost. Two rows were wrong by a factor of four
and six before this was caught, and both were the gasless-path functions we had been quoting
as headlines:

| Call | Published (wrong) | Corrected | Why it was wrong |
|---|---|---|---|
| `createStreamWithPermit` | median 70,772 | **275,876** | 6 calls, 4 of them deliberate reverts from the abuse tests |
| `creditArrival` | median 30,857 | **198,696** | 5 calls, most of them the forwarder-only rejection |

The figures below are **success-path** gas. Where a row is measured across many calls the
median is meaningful; where a function has only a handful of calls we re-ran it in isolation
with `--match-test` so the number describes a call that actually succeeded.

| Call | Success gas | Calls | Note |
|---|---|---|---|
| `accrued` | 1,936 median · 9,936 max | 557 | view, no writes — poll it every block |
| `withdrawable` | 2,129 median · 2,458 max | 716 | view |
| `streams` | 1,397 median · 9,397 max | 761 | view; median is warm storage, max is cold |
| `withdrawAll` | **72,184** | 1 | isolated run |
| `withdraw` | 89,499 median | 454 | includes the ERC-20 transfer |
| `resume` | 35,804 median · 44,121 max | 13 | |
| `pause` | 42,792 median | 18 | |
| `cancel` | 87,990 median · 112,108 max | 6 | pays two transfers |
| `setController` | 38,561 | 2 | |
| `createStream` | 212,958 median · 216,089 max | 274 | includes `transferFrom` |
| `createStreamWithControllers` | **261,951** | 1 | isolated run, ≤ 4 controllers |
| `createStreamWithPermit` | **275,876** | 1 | isolated run — the gasless path |
| `creditArrival` | **198,696** | 1 | isolated run — forwarder path |

**Cross-checked against a real deployment, not just the test harness.** `tools/test-relay.sh`
relays a genuine EIP-2612 signature over HTTP against a live anvil:

| | gas used | gas declared |
|---|---|---|
| first relay (cold token storage) | 241,924 | 278,212 |
| second relay (warm) | 224,900 | 258,635 |

Lower than the 275,876 forge figure because the test harness deploys the token fresh per
test, leaving more slots cold. Both are reported rather than the more flattering one.

The relay declares `estimate × 1.15`, clamped to a 90,000 floor and a 400,000 ceiling. That
matters specifically because **Monad charges gas on the declared limit, not gas used** — a
fixed 400,000 would have overpaid by ~30 % on every relay.

Mainnet deployment dry-run on 2026-10-07: **0.495385002 MON** (2,452,401 gas at a 100 gwei base fee) for both contracts.

Contract sizes are taken from the forge artifact's `deployedBytecode` and confirmed against
on-chain `codesize` after deployment — both say **6,783** and **1,927**. Note the gas report's
own "Deployment Size" column disagrees (6,966); where two independent measurements agree and
one disagrees, we publish the two.

---

## 6. Web app — `apps/web`

Next.js 15.5.27 App Router · React 19 · TypeScript 5.7.2 · viem 2.37.6 · `@category-labs/mera` 0.2.0 · 4,389 lines across contracts, tests and app.

| File | Role |
|---|---|
| `lib/config.ts` | Chain defs (mainnet defined here — viem lacks it), verified token addresses, `GAS_LIMITS`, 300 ms poll cadence, local-anvil mode |
| `lib/abi.ts` | **Generated from forge artifacts** by `tools/gen-abi.py`, never hand-written |
| `lib/mera.ts` | The three-key passkey vault layer |
| `lib/permit.ts` | EIP-2612 signing via `signTypedData` + `parseSignature` |
| `lib/format.ts` | 6-decimal money formatting; integer units internally, never floats |
| `app/api/rpc/route.ts` | Allowlisted JSON-RPC proxy |
| `app/api/relay/route.ts` | The gasless relay — broadcasts a signed permit so the payer never transacts |
| `app/h/[handle]/page.tsx` | The recipient's public page route — `force-dynamic`, since a handle only exists on-chain |
| `lib/scan.ts` | Handle resolution, bounded stream enumeration, and stream-phase derivation |
| `components/RecipientView.tsx` | The public page: live accruing balances with no wallet connected |
| `app/pay/[handle]/page.tsx` | Pay-a-handle route |
| `components/PayerView.tsx` | Pay with a browser wallet and no Moname account |
| `components/Moname.tsx` | The whole flow |

### 6.1 Passkeys: one passkey, three keys

Mera's secret-vault API encrypts arbitrary bytes under a WebAuthn PRF output. Moname uses it to put three keys under one passkey:

| Key | Mera call | Can |
|---|---|---|
| owner | `createSecretVaultWithNewPasskey` (the ceremony that creates the passkey) | fund streams, set terms, appoint controllers |
| session | `createSecretVaultWithExistingPasskey` | `pause` / `resume` / `cancel` only — a StreamVault controller |
| receiving | `createSecretVaultWithExistingPasskey` | be paid; what `@handle` resolves to |

`toViemAccount(session)` returns a viem account that signs digests with the live session key,
so **only the unlock prompts** — afterwards signing is silent, which is what makes a
per-second UI usable. `session.end()` zeroes the key irreversibly.

Vaults are stored in `localStorage` and re-validated through `parseSecretVault` on read,
because untrusted input should never be trusted blindly.

Two API details found by typechecking against the real package before building UI on it:
viem 2.37 **removed `splitSignature`** in favour of `parseSignature`, and Mera's ceremonies
take **different shapes** — creation wants `rp: { id, name }`, assertion wants a bare
`rpId: string`.

`PRF_UNAVAILABLE` is translated into plain English in the UI: on desktop Chrome only passkeys
saved to **Google Password Manager** return a PRF output, and a passkey in the browser's local
profile will fail. Monad's own Mera notes call this the most common setup failure, so it is
handled rather than discovered mid-demo.

### 6.2 Why an RPC proxy

Chain reads go through `app/api/rpc` rather than a browser → public-RPC call, for two reasons:
public-RPC CORS behaviour is not something to bet a demo on, and the preview host is not
localhost. The proxy allowlists methods, so `eth_getLogs` is refused with `-32601` —
appropriate, since Monad caps it at 100 blocks anyway.

The proxy never sees a private key. Signing happens in the browser via the passkey session;
the proxy is a byte pipe for `eth_call`, `eth_sendRawTransaction` and friends.

### 6.3 It refuses to fake being live

When contract addresses are unset, the UI says so and disables on-chain actions rather than
rendering a mockup that looks live. §9.1 asks for a functioning prototype, not a mockup, and
a demo that silently does nothing is worse than one that admits its state.

`NEXT_PUBLIC_CHAIN=local` runs against a Monad-mode anvil with `MockAUSD` — 6 decimals, symbol
`AUSD`, a real EIP-712 `DOMAIN_SEPARATOR`, so the permit path is exercised for real. Its open
`mint` is why a **mint test funds** button appears in local mode *only*, labelled as such: the
real AUSD is a permissioned-mint proxy with no public faucet.

---

## 7. Test coverage — 58 tests, 0 failures

`forge test --network monad --fuzz-runs 2000` · Foundry v1.8.5 · `network = "monad"` so tests run under Monad's gas model, opcode pricing, transaction rules, precompiles and 128 KB limit rather than generic EVM assumptions. `via_ir = true` is required (the 12-field struct otherwise blows the stack).

| Area | Tests |
|---|---|
| Accrual correctness | `isLinearBySecond`, `advancesPerBlock_likeMonad` (200 withdrawals at one per 300 ms), `neverExceedsPrincipal_afterEnd`, `roundsDown_neverUp`, `isIndependentOfSettlementTiming` |
| Pause / resume | `pause_freezesAccrual`, `pause_authorisation`, `pause_autoUnfreezesAtScheduledExpiry`, `resume_preservesFullPrincipal`, `resume_afterExpiry_doesNotOverShift`, `resume_afterExpiry_permissionless`, `resume_beforeExpiry_byOutsider_reverts`, `resume_whenNotPaused_reverts`, `pauseResume_multipleCycles_conserveTotal`, `unsettledPause_afterWindowOverrun_doesNotStickBelowFull` |
| Gasless | `gasless_payerSignsAndNeverSendsATransaction`, `gasless_permitCannotBeReplayed`, `gasless_expiredDeadlineReverts`, `gasless_amountMismatchReverts`, `gasless_permitIsBoundToThisVault` |
| Inbound / forwarder | `creditArrival_forwarderOnly`, `creditArrival_rejectsNonForwarder`, `creditArrival_disabledWhenForwarderIsZero`, `creditArrival_withRealUSDC` |
| Cancel & refund | `cancel_splitsAccruedAndRemainder`, `cancel_afterPartialWithdraw_isExact`, `cancel_sessionKeyCanButRecipientCannot`, `cancel_twiceReverts` |
| Withdraw auth | `withdraw_recipientOnly`, `withdraw_rejectsOverdraw`, `withdraw_partialThenRest` |
| Controllers | `controllers_setAtCreation`, `controllers_cappedAtFour`, `controllers_onlySenderMayChange`, `controllers_senderCanRevoke` |
| Handles | 13 tests incl. charset rejections (uppercase, hyphen, dot, empty, over-length, taken), `registerTo_separatesOwnerFromReceivingKey`, `release_freesTheHandle`, `transferHandle_ownerOnly` |
| Tokens | `oneVaultServesAUSDandUSDC`, `bothStablecoinsShareOurAssumptions` |
| **Mainnet fork** | `realAUSD_identity`, `realAUSD_supportsPermit`, `streamRealUSDC_endToEnd`, `creditArrival_withRealUSDC`, `creditArrival_rejectsNonForwarder`, `bothStablecoinsShareOurAssumptions` |
| Fuzz | `testFuzz_neverOverpays` — fuzzed durations, pause windows and withdrawal patterns, asserting `withdrawn <= amount` always |

**Fork tests run against live Monad mainnet (chain 143)**, not mocks: real Circle USDC streamed
end to end (create → accrue → mid-stream withdraw → pause → stranger rejected → expiry with no
`resume()` auto-unfreezing → full principal → vault drained to exactly zero).

**Documented fork limitation:** AUSD's balance mapping is not at a discoverable low storage
slot, so neither forge-std's `deal` nor a 1024-slot scan can fund an account with it on a fork.
AUSD's identity, decimals, supply and permit domain are asserted against live state;
AUSD-*funded* flows are covered on testnet, where the bytecode is identical. Stated in the test
file header rather than quietly skipped.

Regression tests are verified to **fail without their fix** — that check is what separates a
test that pins behaviour from one that merely passes.

---

## 8. Deliberately not built

Scope discipline recorded in `ROADMAP.md`, so the cuts read as decisions rather than gaps:
payroll/batching, payment walls, pay codes/QR, an HTTP 402 agent API, a premium-handle
marketplace, a native mobile app, Aurora Intents for inbound (withdrawals paused across 11
networks including Monad after the 1 Oct 2026 Omni exploit), the **naira off-ramp as a built
feature**, and on-chain `secp256r1` passkey verification.

**On naira specifically:** it was never in the brief. It entered because Monad's own
integration docs list Switch as settling USDC and USDT0 on Monad into NGN, and it looked like a
natural ending to the story. It is now a documented exit rather than a feature, for a concrete
reason: **Switch settles USDC and USDT0, not AUSD**, so a naira leg needs an AUSD→USDC swap
through the Curve 3pool first — an extra hop, slippage and dependency added in the final week.
The off-ramp is a real business relationship worth describing; it is not worth wiring up under
deadline.

---

## 9. Relationship to WinkPay (§4.1.4 disclosure)

**WinkPay is my payments business**, on Tempo. Tempo cannot do what comes next: per-second
streaming is uneconomic on a ~1 s chain, and cross-border inbound cost 2.5 % on small
transfers. Monad can — 300 ms blocks, deterministic finality at ~600 ms, native Circle USDC,
and CCTP V2 where Circle charges Monad **0 bps** because its finality is already fast enough.
So the cross-border streaming layer of the business is being built on Monad.

- **Pre-existing, used as a foundation (off-chain only):** payments-orchestration patterns — bridge route quoting, a reconciler loop, a multi-chain watcher — plus money-loop and schema design and general Next.js/Drizzle/viem project structure.
- **New, built during the Hackathon period:** everything on-chain. WinkPay contains **no Solidity**; `StreamVault` and `HandleRegistry` are new and are the core of this submission. Also new: the pause/resume accrual model and its invariants, Mera passkey integration and the three-key hierarchy, the permit + relayer gasless path, and streaming itself.

The WinkPay business repository stays private. This repository is public from its first commit,
under MIT, and contains no WinkPay source. **AI coding tools were used**, as §4.1.4 permits and
requires be disclosed. Contract logic was verified by running it, and the accrual model was
corrected several times by *failing tests* rather than accepted as generated.

---

## 10. What is left

| # | Item | Blocker |
|---|---|---|
| 1 | Push to a **public** GitHub repo | Needs the owner's GitHub credentials. Urgent: the sandbox wipes `.git` between tool calls, and §4.1 grades commit history covering the build window. A verified git bundle is kept as a stopgap. Commits must **not** be back-dated to fake history — §10.1 disqualifies for false or misleading information |
| 2 | Deploy to mainnet (143) | Needs ~0.5 MON. Then record addresses **and** tx hashes in the README (§9.2 accepts either; we record both) |
| 3 | Resolve the Agora bounty's **"mobile app"** wording | The requirement says mobile app; we build responsive web. That wording is worth 40 % of $10k. Message Agora in Discord — their CEO and CTO run the bounty and both mentor |
| 4 | AUSD-funded flows on testnet | Real test AUSD; Agora's testnet mint is permissioned and sources conflict on whether a public faucet exists |
| 5 | Cross-chain inbound | Relay by default; a time-boxed CCTP V2 spike only if streaming is already solid |
| 6 | Demo video ≤ 3 min (§9.4) | Needs 1–5 above. Test Mera on the exact demo machine first |
| 7 | Envio HyperSync indexer | Post-hackathon; Monad nodes do not serve historic state |

**Shipped since the last revision:**
- the recipient landing page (§2.6) — `/h/@handle`, read-only, no wallet, live `accrued()` polling at 300 ms
- the gasless relay (§6.2) — `app/api/relay`, so a permit signer never sends a transaction
- the payer page (§2.7) — `/pay/@handle`, pay with a browser wallet and no Moname account
- `tools/local-dev.sh` and `tools/test-relay.sh`, so the whole local demo and its gasless proof are one command each

**Newly surfaced by building it:** `lib/scan.ts` enumerates streams with a bounded reverse walk
of the stream counter (`SCAN_WINDOW = 64`), because Monad's `eth_getLogs` cap makes event
scanning useless. That is O(streams ever created), not O(this recipient's streams). The fix is
either an on-chain `mapping(address => uint256[])` index in StreamVault or an Envio indexer.
We deliberately did **not** add the on-chain index in the final week: StreamVault is fork-tested
against live mainnet with 58 passing tests, and that verification is worth more than a cheaper
read. Item 7 above is now load-bearing rather than optional.
