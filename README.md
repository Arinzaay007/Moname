# Moname

**Repository:** <https://github.com/Arinzaay007/Moname> · MIT licensed

**Money that arrives from anywhere and streams in by the second, in Agora's AUSD, on Monad mainnet.**

Built for [Monad Metropolis](https://monad.xyz/developers/hackathons/metropolis) — Track 2, Consumer Products & Payments.

A freelancer in Port Harcourt shares `@arinza`. A client in Berlin pays from whatever chain they happen to hold. It lands on Monad as **AUSD** in under a second, and from that moment it **streams to her by the second** — not on delivery, not on invoice terms, not net-30. She pays for it with a signature and never sends a transaction, so she never needs to hold gas. She never sees a seed phrase and never hears the word "blockchain".

**Token: AUSD** (`0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`), Agora's dollar stablecoin — the token the Agora cross-border bounty names. **Network: Monad mainnet, chain 143.** See [Deployment](#deployment).

Getting money *out* into a local currency is a documented exit, not a built feature, and `ROADMAP.md` says why: the Monad-integrated off-ramps settle USDC and USDT0 rather than AUSD, so a fiat leg needs a swap first. That is a real partnership to describe, not something to wire up in the final week.

Three wedges, one flow: **cross-border** is the money coming in, **gasless** is how the user gets on, **streaming** is how the money goes out.

---

## Why this needs Monad

Per-second streaming is the whole product, and it is the part that cannot be built anywhere else:

| | Blocks | Finality | Per-second accrual |
|---|---|---|---|
| Ethereum | ~12 s | ~13 min | Uneconomic — one withdrawal costs more than a day's accrual |
| Tempo | ~1 s | — | Marginal |
| **Monad** | **~300 ms** | **~600 ms deterministic** | **Trivial — a withdrawal is ~89k gas and accrual is a free read** |

At 300 ms blocks the recipient can call `withdraw` on every single block and it is still rational. On Ethereum that is 3 withdrawals a minute at mainnet prices. This is not a throughput brag; it changes what the product can promise. `test/StreamVault.t.sol::test_accrual_advancesPerBlock_likeMonad` simulates exactly that — 200 withdrawals, one per ~300 ms block — and asserts the recipient is never overpaid by a wei.

Two more Monad properties this codebase leans on:

- **MIP-8 storage pages** warm 128 consecutive slots at a time. The 12-field `Stream` struct is laid out so a stream occupies one page, which is why `accrued()` reads at **~1.9k gas**. The UI polls it every block.
- **The `secp256r1` precompile at `0x0100`** (EIP-7951) makes on-chain passkey verification possible. That is the long-term version of the key model below.

Circle's own CCTP V2 fee table lists **Monad at 0 bps** for Fast Transfer, because "standard attestation times are already fast enough". That is a third party pricing Monad's finality as effectively free.

---

## Contracts

| Contract | Size | What it does |
|---|---|---|
| `src/StreamVault.sol` | 6,783 B (128 KB limit) | Money streaming with pause, resume, cancel, delegated controllers, and forwarder-credited arrivals |
| `src/HandleRegistry.sol` | 1,927 B | `@handle` → address. Pay someone without ever showing them a hex string |

### Gas (Monad execution model, `forge test --network monad --gas-report`)

| Call | Success gas | Calls | Note |
|---|---|---|---|
| `accrued` | 1,936 median · 9,936 max | 557 | view, no writes — poll it every block |
| `withdrawable` | 2,129 median · 2,458 max | 716 | view |
| `streams` | 1,397 median · 9,397 max | 761 | view; median warm, max cold |
| `withdrawAll` | 72,184 | 1 | |
| `withdraw` | 89,499 median | 454 | includes the ERC-20 transfer |
| `resume` | 35,804 median | 13 | |
| `pause` | 42,792 median | 18 | |
| `cancel` | 87,990 median | 6 | pays two transfers |
| `createStream` | 212,958 median | 274 | includes `transferFrom` |
| `createStreamWithControllers` | 261,951 | 1 | ≤ 4 controllers |
| `createStreamWithPermit` | 275,876 | 1 | the gasless path |
| `creditArrival` | 198,696 | 1 | relayer path, see below |

Reproduce: `forge test --network monad --gas-report`, and `./tools/test-relay.sh` for the figures measured against a real deployment.

> **These are success-path numbers, and that distinction is worth stating.** Forge's gas report aggregates every call to a function across the suite, *including* calls inside `vm.expectRevert` tests. For a function covered mostly by negative tests the median is a revert cost, not a success cost. An earlier version of this table quoted a median of 70,772 for `createStreamWithPermit` and 30,857 for `creditArrival`; the real successful calls cost **275,876** and **198,696**. Both wrong rows were the gasless functions we were quoting as headlines. Rows with few calls are now measured in isolation with `--match-test` so the number describes a call that succeeded.

Measured against a live anvil through the actual HTTP relay, the same call costs 241,924 gas used / 278,212 declared on a cold first relay and 224,900 / 258,635 warm — lower than the harness figure because the test suite deploys the token fresh each time, leaving more slots cold. Both are reported rather than the flattering one.

### The accrual model, and the one decision worth reading

`Stream` stores `start`, `end`, `pausedFrom`, `pausedUntil`, `pausedTotal`. `accrued()` computes

```
span     = end - start                  // wall window; grows when a pause is settled
accruing = span - pausedTotal           // the window that actually pays
reached  = live ? pausedFrom - start    // frozen while a pause is running
                : now - start           // running otherwise
reached -= unsettledPauseInterval       // subtract BEFORE clamping — see below
reached  = min(reached, accruing)
accrued  = amount * reached / accruing
```

The subtraction must happen **before** the clamp, and that ordering is a bug that was found and fixed. Clamping `reached` to the window first means that once the clock runs past `end` with a pause still unsettled, the clamp has already eaten the headroom the subtraction needed — so `accrued` sticks at `(span - pause) / span` forever. On a 1000 s stream with a 300 s abandoned pause that is a recipient permanently capped at 70 % of money that had fully accrued. `test_unsettledPause_afterWindowOverrun_doesNotStickBelowFull` pins it, and was verified to fail against the buggy ordering with exactly that 70 % figure.

The design decision: **a pause is bounded by its own terms.** `pause(id, until)` freezes accrual until `until`, and accrual restarts at `until` *whether or not anyone ever calls `resume()`*.

The alternative — freeze until someone resumes — means a sender who pauses a stream and walks away has silently destroyed the recipient's income. On a payment rail that is not acceptable, and it is exactly the kind of thing that would not surface until a real user hit it. So:

- `resume()` before expiry → **sender or controller only**. Ending a pause early is a decision.
- `resume()` after expiry → **permissionless**. Anyone, including the recipient, can settle an abandoned pause.
- Settlement moves `end` and `pausedTotal` together, so **it never changes what `accrued()` returns**. It only makes the shift permanent. `test_accrual_isIndependentOfSettlementTiming` walks two identical streams — one settled promptly, one not — across 30 instants and asserts their curves agree.

Principal is conserved across any number of pause/resume cycles: the recipient always receives the full `amount`, just later in wall-clock terms.

### Key model — "one passkey, many keys"

`createStreamWithControllers` takes up to four additional addresses that may `pause`, `resume` and `cancel`, but **may not move funds and may not change the terms**. This is the on-chain half of a Mera passkey hierarchy:

| Key | Can | Contract surface |
|---|---|---|
| Owner (index 0) | fund, set terms, appoint controllers | `createStream`, `setController`, `cancel` |
| Session (index 1) | operate a live stream | the `controllers` allowlist — `pause` / `resume` / `cancel` |
| Receiving (index 2) | be paid | `HandleRegistry.registerTo(handle, receiving)` |

The key that can move money is not the key that lives in page memory. A compromised browser session can pause a stream; it cannot drain one.

### Gasless inbound: `creditArrival`

AUSD and USDC on Monad both support EIP-2612 `permit` (verified live: both expose a real `DOMAIN_SEPARATOR`), so a payment is a *signature* and the payer never needs MON. Mera hands out plain EOAs, not 4337 accounts, so there is no paymaster. Two paths, both shipped:

- **`createStreamWithPermit`** — the payer signs, a relayer submits. `payer` is an argument rather than `msg.sender`, and the call is deliberately **permissionless**: the signature *is* the authorisation, and gating submission on our relayer would make it a liveness bottleneck for someone's payroll. The permit consumes its nonce and pins payer, spender, amount and deadline, so it cannot be replayed, stretched, expired or redirected. Five tests cover exactly those four abuses plus the happy path, and were verified to fail when the permit call is broken.
- **`creditArrival`** — for bridged inbound, where tokens have **already landed in the vault**. Forwarder-only, and it does *not* call `transferFrom`, because doing both would charge the payer twice.

> ⚠️ Monad charges gas on the **declared limit**, not gas used. The relayer must always pass an explicit gas figure.

---

## Running it

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # needs Foundry >= v1.8
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
forge build
forge test --network monad                 # 58 tests
forge test --network monad --fuzz-runs 5000
```

`foundry.toml` sets `network = "monad"`, so tests run under Monad's gas model, opcode pricing, transaction rules, precompiles and 128 KB code limit rather than generic EVM assumptions. `via_ir = true` is required: the 12-field struct would otherwise blow the stack in the test destructuring.

### Deploying

```bash
# local, in Monad mode — chain id and hardfork are picked up automatically
anvil --network monad --chain-id 10143
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast

# Monad testnet
forge script script/Deploy.s.sol:Deploy \
  --rpc-url monad_testnet --broadcast \
  --private-key $MONAD_PRIVATE_KEY \
  --verify --etherscan-api-key $MONADSCAN_API_KEY
```

Set `FORWARDER_ADDRESS` to the relayer. Left unset it deploys as `address(0)`, which makes `creditArrival` revert `ZeroAddress` — no gasless path rather than an open one.

Pass explicit gas. Monad charges on the declared limit, so an over-estimate is real money.

### Test coverage

58 tests. The ones that matter:

- `test_gasless_payerSignsAndNeverSendsATransaction` — payer holds **0 MON**, signs a permit, a relayer submits, and the payer ends up owning the stream. Plus four abuse cases: replay, expired deadline, stretched amount, redirected spender.
- `test_oneVaultServesAUSDandUSDC` — one deployment, both tokens, both 6 decimals.
- `testFuzz_neverOverpays` — fuzzed durations, pause windows and withdrawal patterns; asserts `withdrawn <= amount` always.
- `test_accrual_advancesPerBlock_likeMonad` — 200 withdrawals at one per 300 ms block.
- `test_pauseResume_multipleCycles_conserveTotal` — three pause/resume cycles; principal fully conserved.
- `test_pause_autoUnfreezesAtScheduledExpiry` — the forgotten-resume regression.
- `test_accrual_isIndependentOfSettlementTiming` — settlement timing never moves the payout curve.
- `test_unsettledPause_afterWindowOverrun_doesNotStickBelowFull` — the clamp-ordering regression above.
- `test_pause_autoUnfreezesAtScheduledExpiry`, `test_resume_afterExpiry_permissionless`, `test_resume_beforeExpiry_byOutsider_reverts` — the pause-auth and forgotten-resume semantics.
- `test_creditArrival_*` — forwarder-only, no double charge, disabled when unconfigured.

---

## Web app

`apps/web` — Next.js 15 App Router, React 19, TypeScript, viem 2.37, `@category-labs/mera` 0.2.0.

```bash
cd apps/web && npm install && npm run dev
```

It reads chain state through `app/api/rpc`, a server-side JSON-RPC proxy, rather than calling a public RPC from the browser: CORS on public RPCs is not something to bet a demo on, and the preview host is not localhost. The proxy allowlists methods, so `eth_getLogs` is refused outright — Monad caps it at a 100-block range anyway and full nodes do not serve arbitrary historic state, so the UI reads live state instead of reconstructing history.

### Paying with no account — `/pay/@handle`

The mirror of the recipient page, and it removes the other half of the onboarding friction. Paying used to require creating a passkey and unlocking the owner key — so a payer had to onboard to Moname just to send money once. That is backwards.

`/pay/@handle` needs a browser wallet holding AUSD and nothing else. Connect, enter an amount and a duration, sign one EIP-2612 permit. No Moname account, no passkey, no MON, no transaction sent — the relay broadcasts it. The page says plainly that a permit is a signature and not a transaction, shows the per-second rate before you commit, and explains what you are agreeing to: the full amount leaves your wallet into the vault immediately, the recipient can cancel nothing but you can, and whatever has accrued is theirs because they earned it.

The asymmetry is the product. **Receiving** needs zero setup because a passkey creates your identity. **Paying** needs no Moname identity at all.

### The gasless relay — `/api/relay`

`createStreamWithPermit` is permissionless, so anyone can submit a signed permit. The relay exists so the payer does not have to.

The payer signs an EIP-2612 permit in the browser. That signature binds owner, spender, value and deadline, so nobody — not this service, not anyone else — can alter the terms it relays. The payer hands it to `/api/relay` and **never sends a transaction**, which is what makes "no gas" literally true rather than aspirational.

Three details that matter:

- **It simulates before spending.** A reverted relay still costs gas, so the route `eth_call`s first and returns 422 without broadcasting if the vault would reject the permit. This is the main defence against being used to burn the relayer's balance.
- **It declares gas tightly.** Monad charges on the *declared* limit, not gas used, which inverts the usual "add generous headroom" instinct. The relay estimates and declares `estimate × 1.15`, clamped to a 90,000 floor and a 400,000 ceiling. A fixed 400,000 would overpay roughly 30% on every relay.
- **It fails honestly.** With `RELAYER_PRIVATE_KEY` unset the route returns 503, and the UI falls back to letting the payer broadcast their own permit — but then says so out loud, because in that mode the payer *is* paying gas and the "gasless" label would be a lie. The UI probes `GET /api/relay` on boot so the claim next to the button reflects reality.

Sends are serialised through a promise chain, because viem derives the nonce from `pending` and two concurrent relays would compute the same one. A single-process demo can do this; a real deployment needs a nonce manager backed by shared state. The rate limit is likewise in-memory and per-IP, and is documented as best-effort rather than dressed up as abuse protection — the real protection is that a permit can only ever move the signer's own funds by the signer's own chosen amount.

The key is server-side only, with no `NEXT_PUBLIC_` prefix, so it can never be inlined into a client bundle. It only ever pays gas; it can never move anyone's funds.

Prove the whole path with:

```bash
./tools/local-dev.sh     # deploy + seed a local Monad-mode anvil
./tools/test-relay.sh    # sign a real permit, relay it over HTTP, assert the payer never transacted
```

`test-relay.sh` is the HTTP-level counterpart to `test_gasless_payerSignsAndNeverSendsATransaction`. The Solidity test proves the *contract* cannot charge a payer who did not sign. The script proves the path a real user takes, and asserts the payer's transaction count is still zero afterwards, that the permit nonce was consumed so it cannot be replayed, and that replaying it anyway is refused with 422 and no gas spent.

### The recipient's public page — `/h/@handle`

A payment page that opens with **no wallet, no passkey, no account and no setup**, because the person looking at it is often not the person being paid. It resolves the handle on-chain, finds the streams addressed to that receiving key, and polls `accrued()` for each active one every 300 ms — the balances visibly climb, several times a second. Withdrawing is the only gated action, and it needs the receiving key.

Finding those streams is the interesting constraint. Monad nodes do not serve arbitrary historic state, and `eth_getLogs` is capped at a 100-block range — about **30 seconds** of history at 300 ms blocks — so event scanning cannot answer "show me my payments". `lib/scan.ts` therefore walks the stream counter backwards over live current state and keeps the rows whose recipient matches. No indexer, no archive node.

That is O(streams ever created) rather than O(this recipient's streams), bounded by `SCAN_WINDOW = 64`, and the page says so on itself instead of hiding it. The fixes are an on-chain per-recipient index or an Envio HyperSync indexer — see ROADMAP.md. We chose not to modify StreamVault in the final week to add the former: it is fork-tested against live mainnet with 58 passing tests, and that verification is worth more than a cheaper read.

### Passkeys: one passkey, keys created on demand

`lib/mera.ts` uses Mera's secret-vault API to put **separate keys under one passkey**, each with a different power:

| Key | Created | Can |
|---|---|---|
| **receiving** | **at signup**, via `createSecretVaultWithNewPasskey` (the ceremony that creates the passkey) | be paid; what `@handle` resolves to; withdraw accrued funds |
| owner | on first use, via `createSecretVaultWithExistingPasskey` | fund streams, set terms, appoint controllers |
| session | on first use, via `createSecretVaultWithExistingPasskey` | `pause` / `resume` / `cancel` — registered as a StreamVault controller, so it cannot withdraw or change terms |

**Why lazy.** Every Mera ceremony shows a user-verification prompt, and Mera documents that the requirement *"is not configurable"* — `createSecretVaultWithNewPasskey` shows one (two on authenticators that do not evaluate PRF at creation) and each `createSecretVaultWithExistingPasskey` shows one more. Creating all three up front therefore cost **three or four prompts at signup** for keys most users never touch. A recipient needs exactly one of them to get paid. Signup is now **1–2 prompts**.

`ensureKey(role)` costs **exactly one prompt either way**: if the vault exists it decrypts it; if not it creates it and returns it live, because the private key was just generated locally and is still in memory — spending a second ceremony to decrypt a vault written a moment ago would be pure friction.

`toViemAccount` signs digests with the live session key, so **only the unlock shows a prompt** — after that, signing is silent, which is what makes a per-second streaming UI usable. `session.end()` zeroes the key irreversibly.

**One prompt for all three is not available honestly.** Mera does export no-ceremony primitives (`createSecretVault`, `decryptSecretVault`) that would let a single PRF output key all three vaults. They are unreachable: the package root does not re-export them and the `exports` map (`.`, `./viem`, `./react-native-webauthn-client`) blocks subpath imports. Verified at runtime, not assumed. Using them would mean reimplementing Mera's AES-256-GCM vault format against undocumented internals, which is not a trade worth making in a payments product.

Mera's two ceremonies take different argument shapes: creation wants `rp: { id, name }`, assertion wants a bare `rpId: string`. `lib/mera.ts` is typechecked against the real package before any UI is built on it, which is how that got caught.

`PRF_UNAVAILABLE` gets a plain-English explanation in the UI rather than a stack trace: on desktop Chrome only passkeys saved to **Google Password Manager** return a PRF output, and a passkey in the browser's local profile will fail. This is documented as the most common setup failure, so it is handled rather than discovered mid-demo.

**Unverified: whether PRF survives passkey sync to a new device.** Passkeys sync via iCloud Keychain and Google Password Manager, so in principle a Mera vault follows a user to a new phone. But Mera needs the WebAuthn PRF extension, and PRF is already known to be fragile on desktop Chrome. Cross-device recovery is therefore *plausible but untested*, and should be tested on two real devices before being promised to anyone. This is the one place where an email-based custodial wallet has a genuine advantage over a passkey.

### Hosting the web app

The production build passes clean (`npm run build` — six routes, 222 kB worst-case First Load JS). On Vercel:

1. Import the repository and set **Root Directory** to `apps/web`. There is no workspace config at the repo root, so `apps/web` is standalone and needs nothing else.
2. Framework preset **Next.js**; build command `npm run build` (the default).
3. Set three environment variables — **never commit them**:

| Variable | Value | Scope |
|---|---|---|
| `NEXT_PUBLIC_CHAIN` | `mainnet` | public, inlined into the client bundle |
| `MONAD_RPC_URL` | `https://rpc.monad.xyz` | server only |
| `RELAYER_PRIVATE_KEY` | a funded key | **server only** — no `NEXT_PUBLIC_` prefix, so it cannot reach the client bundle |

Contract addresses are **not** environment variables: `lib/config.ts` carries the mainnet ones as defaults, so the deployed app points at the live deployment with nothing further. Setting `NEXT_PUBLIC_CHAIN` to `local` or `testnet` disables those defaults deliberately, so the app refuses to pretend it is connected when addresses are unset.

**Passkeys bind to the hostname.** WebAuthn's relying-party id comes from `window.location.hostname`, so a passkey created on one domain will not unlock on another. Pick the production domain before anyone creates a passkey you intend to keep — a preview deployment URL and a custom domain are different relying parties.

**Two relay limits that serverless makes real rather than theoretical**, both documented at their definitions in `app/api/relay/route.ts`:

- Sends are serialised through a module-level promise chain, which holds within one instance but **not across Vercel's concurrent instances**. Two simultaneous relays can collide on a nonce and one fails. The failure is safe — a dropped transaction, never a lost or doubled payment, since the permit nonce is consumed on chain exactly once — but a production relayer needs shared-state nonce management or a single long-lived process.
- The per-IP throttle is in-memory, so the effective limit is per instance, not per service.

Neither is abuse protection, and neither is presented as such. The real protection is that a permit can only ever move the signer's own funds by the signer's own chosen amount.

### Running it without a mainnet deployment

§9.1 wants a functioning prototype, and one that cannot start until someone funds a key is not one. So `NEXT_PUBLIC_CHAIN=local` runs against a Monad-mode anvil:

```bash
anvil --network monad --chain-id 10143 --block-time 1
forge create test/mocks/MockAUSD.sol:MockAUSD --rpc-url http://127.0.0.1:8545 --private-key $PK --broadcast
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast --private-key $PK
```

`MockAUSD` mirrors the real token's surface — 6 decimals, symbol `AUSD`, a real EIP-712 `DOMAIN_SEPARATOR` — so the permit path is exercised for real. Its `mint` is open, which is why the UI shows a **mint test funds** button *only* in local mode, labelled as such: the real AUSD is a permissioned-mint proxy with no public faucet.

The UI also refuses to pretend: when contract addresses are unset it says so and disables on-chain actions rather than rendering a mockup that looks live.

`npm audit` currently reports 4 transitive advisories (postcss and ws via next and viem, both needing breaking upgrades). Neither is in a path this app uses — `sharp` is next/image, which is not used, and `ws` is viem's WebSocket transport, while this app uses HTTP only. Recorded rather than silently accepted.

## Deployment

**Primary token: Agora AUSD.** The Agora cross-border bounty names AUSD specifically, and AUSD is the only dollar stablecoin deployed on *both* Monad networks — identical bytecode, codesize 5937 on mainnet and testnet. USDC is secondary and mainnet-only.

StreamVault is token-agnostic (`address token`), and both AUSD and USDC are 6 decimals and permit-capable, so supporting both is configuration rather than code. `test/Fork.t.sol::test_bothStablecoinsShareOurAssumptions` asserts exactly that against live mainnet.

| Token | Mainnet (143) | Testnet (10143) | Decimals | Permit | Notes |
|---|---|---|---|---|---|
| **AUSD** (Agora) | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` | `0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC` | 6 | EIP-2612 + EIP-3009 | primary; EIP-1967 proxy, impl `0xc1e3C7D486d6A92fBE920232E439EeC2cEb112dA`; mainnet supply 144,570,251 AUSD |
| **USDC** (Circle) | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` | not deployed | 6 | EIP-2612 | secondary; CCTP V2 inbound at 0 bps |

All values read off-chain with `cast` on 2026-10-07 and re-asserted by the fork suite, not copied from a third-party README.

### Deployments

**Monad mainnet, chain 143 — deployed 2026-10-08.** Full record with monadscan links in [`DEPLOYMENT.md`](DEPLOYMENT.md).

| Contract | Address | Deploy tx | Gas used |
|---|---|---|---|
| `StreamVault` | `0x2c0dd3385d545d54d7185432365917abfd62e52f` | `0xb39315ae2e37f1446c24e8a6a9a2eb7b8036a0c80857b31812477670aeb71c86` | 2,055,086 |
| `HandleRegistry` | `0x87dbd64e79e11510223299600f8d67428f82e710` | `0xe34c8097da6ecbf8e5273da45a68f09e67dbeac40421d9e8ea100f3c325d3485` | 617,203 |

| | |
|---|---|
| Total gas | **2,672,289** — exactly the pre-deploy dry-run estimate |
| Actual cost | **0.272573478 MON** (100 gwei base fee + 2 gwei priority) |
| Runtime sizes on chain | StreamVault **6,783 B**, HandleRegistry **1,927 B** — byte-identical to the compiled artifacts |
| `StreamVault.forwarder()` | `0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f` — Relay's destination executor |
| `StreamVault.owner()` | `0x0d362Cf9443D6C2FF7Faa20C11111702e7099FC6` (deployer) |
| Verified after deploy | `nextId()` = 0, `isRegistered("arinza")` = false, `resolve("nosuchhandle")` reverts `HandleNotRegistered` — fails closed as designed |

§9.2 accepts contract addresses *or* tx hashes; both are recorded. A figure of 0.495385002 MON for 2,452,401 gas appeared in an earlier revision of this README and was never internally consistent — those numbers do not correspond at any gas price. It is replaced above with the measured spend.

Monad testnet (10143) is not deployed; the local anvil path in [Running it without a mainnet deployment](#running-it-without-a-mainnet-deployment) covers development.

### Owner privileges, stated exactly

`StreamVault`'s owner has **one** power: `setForwarder`. It cannot pause, cancel, withdraw, or appoint controllers — those are gated on the stream's sender or its controllers. There is **no `transferOwnership`**, so ownership is permanently the deployer address above.

The consequence of a compromised owner key is therefore narrow but real: an attacker could install themselves as `forwarder` and redirect *future* cross-chain arrivals. They could not touch existing streams. Recorded here rather than left implicit, because it is the kind of thing a reviewer should not have to read the source to find.

### Proven against live mainnet, not just mocks

`test/Fork.t.sol` forks chain 143 and runs the whole product against real tokens: real USDC streamed end to end (create → accrue → mid-stream withdraw → pause → stranger rejected → expiry with no `resume()` auto-unfreezing → full principal → vault drained to exactly zero), plus `creditArrival` with no double charge. Real AUSD's identity, decimals, supply and EIP-712 permit domain are asserted against live state.

**Documented limit:** AUSD's balance mapping is not at a discoverable low storage slot, so neither forge-std's `deal` nor a 1024-slot scan can fund an account with it on a fork. AUSD-funded flows are therefore covered on testnet, where Agora's AUSD is the same bytecode. Stated in the test file rather than quietly skipped.

---

## Relationship to WinkPay — disclosure

Required by Metropolis T&Cs §4.1.4, stated plainly.

**WinkPay is my payments business.** It runs on Tempo. Tempo cannot do what I want next: per-second streaming is uneconomic on a ~1 s chain. Monad can — 300 ms blocks, deterministic finality at ~600 ms, and Circle's own docs mark Monad's CCTP **Fast Transfer as N/A** because "a standard transfer is as efficient as a fast transfer" on it. Monad's finality is already fast enough that Circle does not sell it an express lane. So the cross-border streaming layer of the business is being built on Monad.

**Inbound corridors are measured, not assumed.** WinkPay supports 13 source chains into Tempo. Probing Relay's live quote API for each of those same chains into **Monad 143** (`tools/probe-13-chains.py`, `tools/probe-nonevm-corridors.py`) shows **12 of the 13 route in**, each delivering both USDC and AUSD: Base, Ethereum, Arbitrum, Optimism, Polygon, BSC, Solana, Avalanche, Celo, TON, Robinhood Chain and Plasma. Delivering exactly 100 costs ~**3¢** as USDC or ~**9¢** as AUSD from the EVM corridors — the extra 6¢ is Relay performing the USDC→AUSD swap on Monad — and **0.043% / 0.087%** from Solana. **X Layer is the one genuine gap**, returning `NO_SWAP_ROUTES_FOUND`.

Relay also accepts a **destination contract call** into Monad via its `txs[]` parameter, verified by quoting Base→Monad with `creditArrival`'s calldata and reading it back embedded in `output.calls` by selector. With `EXACT_OUTPUT` the delivered amount is fixed (`minimumAmount == expectedAmount`), so the amount baked into the calldata is exactly what lands and **no proxy contract is needed**. That makes the inbound leg atomic: tokens arrive and the stream opens in one transaction, with no watcher and no polling. The contract required no changes for this — `creditArrival` already fit.

**Pre-existing components used as a foundation** (off-chain only):
- payments orchestration patterns — bridge route quoting, a reconciler loop, a multi-chain watcher
- the money-loop and schema design
- general Next.js / Drizzle / viem project structure

**Substantial new functionality built during the Hackathon period** — that is, essentially all of it:
- **everything on-chain.** WinkPay contains no Solidity. `StreamVault.sol` and `HandleRegistry.sol` are new, written during the build window, and are the core of this submission.
- the pause/resume accrual model and its invariant tests
- Mera passkey integration and the three-key hierarchy
- the `permit` + relayer gasless path and `creditArrival`
- streaming itself, which WinkPay does not have

The WinkPay business repository stays private. This repository is public from its first commit, under MIT, and contains no WinkPay source.

**AI coding tools were used** in building this submission, as §4.1.4 permits and requires be disclosed. All contract logic, invariants and tests were reviewed and verified by running them; the accrual model above was corrected several times by failing tests rather than accepted as generated.

---

## Scope discipline

Explicitly **cut** so the demo is real rather than broad: payroll, payment walls, pay codes, an HTTP 402 agent API, a premium-handle marketplace, and a native mobile app. They are in `ROADMAP.md` as deferred, not as done.

## Security

- No private key has ever been committed. `.env` is gitignored; `.env.example` documents the variable names.
- Reentrancy is guarded with OpenZeppelin's transient-storage `ReentrancyGuardTransient` on every token-moving call.
- `cancel` refunds the unaccrued remainder to the sender and never lets the recipient take more than accrued.
- Integer overflow: Solidity 0.8.26 checked arithmetic; `_linear` widens to `uint256` before multiplying.

## Third-party code

Both dependencies are **vendored** — committed directly into `lib/` rather than referenced as git submodules. That is deliberate: a plain `git clone` builds, with no `--recurse-submodules`, no network fetch and no chance of a pinned upstream commit disappearing. It costs ~900 small text files in the repository and buys reproducibility, which matters more here.

| Dependency | Version | Licence | Used for |
|---|---|---|---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | 5.4.0 | MIT | `SafeERC20`, `ReentrancyGuardTransient`, `Ownable`, `ERC20Permit` (test mock) |
| [forge-std](https://github.com/foundry-rs/forge-std) | 1.17.0 | MIT **or** Apache-2.0 | test harness only; not in `src/` |

Versions are read from each vendored copy's own `package.json`, and licences from the `LICENSE` files committed alongside them — not from memory or a README elsewhere. forge-std ships both `LICENSE-MIT` and `LICENSE-APACHE`.

These were originally added as pinned submodules and were converted to vendored copies before publication. The upstream commit SHAs from that pin are no longer verifiable in the build environment, so they are deliberately **not** quoted here; the committed tree in `lib/` is the authoritative copy and the version numbers above are what it declares.

No other third-party code is included. All Solidity in `src/` is original to this submission.

## Repository history — one disclosed gap

The commit history covers the build window but is coarser in one place than it should be. A commit was lost when the build environment wiped `.git`, and its work is folded into the following commit (`0b8fec6`, the rename to Moname) instead of standing alone. **All of those files are present and correct**; only the granularity is missing. Nothing was reconstructed and no commit was back-dated — the dates are the real ones.

Two commit messages still say "MonPay". That is accurate: they predate `0b8fec6`, which is the rename. They have deliberately not been rewritten, because rewriting them would misrepresent the sequence.

## Licence

MIT — see `LICENSE`.
