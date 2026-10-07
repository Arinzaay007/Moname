# Moname

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

| Call | Avg | Median | Max | Note |
|---|---|---|---|---|
| `accrued` | 1,920 | 1,926 | 9,926 | view, no writes — poll it every block |
| `withdrawable` | 2,145 | 2,113 | 2,183 | view |
| `streams` | 4,328 | 1,368 | 9,368 | view |
| `withdraw` | 81,391 | 89,414 | 89,496 | includes the ERC-20 transfer |
| `withdrawAll` | 73,242 | 72,127 | 89,128 | |
| `creditArrival` | 77,873 | 30,857 | 171,925 | relayer path, see below |
| `pause` | 41,294 | 42,782 | 42,794 | |
| `resume` | 36,195 | 35,781 | 44,134 | |
| `createStream` | 210,591 | 212,931 | 212,931 | includes `transferFrom` |
| `createStreamWithControllers` | 247,083 | 261,908 | 261,908 | ≤ 4 controllers |

Reproduce: `forge test --network monad --gas-report`

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

### The recipient's public page — `/h/@handle`

A payment page that opens with **no wallet, no passkey, no account and no setup**, because the person looking at it is often not the person being paid. It resolves the handle on-chain, finds the streams addressed to that receiving key, and polls `accrued()` for each active one every 300 ms — the balances visibly climb, several times a second. Withdrawing is the only gated action, and it needs the receiving key.

Finding those streams is the interesting constraint. Monad nodes do not serve arbitrary historic state, and `eth_getLogs` is capped at a 100-block range — about **30 seconds** of history at 300 ms blocks — so event scanning cannot answer "show me my payments". `lib/scan.ts` therefore walks the stream counter backwards over live current state and keeps the rows whose recipient matches. No indexer, no archive node.

That is O(streams ever created) rather than O(this recipient's streams), bounded by `SCAN_WINDOW = 64`, and the page says so on itself instead of hiding it. The fixes are an on-chain per-recipient index or an Envio HyperSync indexer — see ROADMAP.md. We chose not to modify StreamVault in the final week to add the former: it is fork-tested against live mainnet with 58 passing tests, and that verification is worth more than a cheaper read.

### Passkeys: one passkey, three keys

`lib/mera.ts` uses Mera's secret-vault API to put **three separate keys under one passkey**:

| Key | Created with | Can |
|---|---|---|
| owner | `createSecretVaultWithNewPasskey` (this is the ceremony that creates the passkey) | fund streams, set terms, appoint controllers |
| session | `createSecretVaultWithExistingPasskey` | `pause` / `resume` / `cancel` — registered as a StreamVault controller, so it cannot withdraw or change terms |
| receiving | `createSecretVaultWithExistingPasskey` | be paid; what `@handle` resolves to |

`toViemAccount` signs digests with the live session key, so **only the unlock shows a passkey prompt** — after that, signing is silent, which is what makes a per-second streaming UI usable. `session.end()` zeroes the key irreversibly.

Mera's two ceremonies take different argument shapes: creation wants `rp: { id, name }`, assertion wants a bare `rpId: string`. `lib/mera.ts` is typechecked against the real package before any UI is built on it, which is how that got caught.

`PRF_UNAVAILABLE` gets a plain-English explanation in the UI rather than a stack trace: on desktop Chrome only passkeys saved to **Google Password Manager** return a PRF output, and a passkey in the browser's local profile will fail. This is documented as the most common setup failure, so it is handled rather than discovered mid-demo.

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

| Network | Chain ID | StreamVault | HandleRegistry | Deploy tx |
|---|---|---|---|---|
| **Monad Mainnet** | 143 | _pending_ | _pending_ | _pending_ |
| Monad Testnet | 10143 | _pending_ | _pending_ | _pending_ |

Mainnet dry-run on 2026-10-07 predicted both addresses and cost **0.495385002 MON** (2,452,401 gas at a 100 gwei base fee). §9.2 accepts contract addresses *or* tx hashes; we record both.

### Proven against live mainnet, not just mocks

`test/Fork.t.sol` forks chain 143 and runs the whole product against real tokens: real USDC streamed end to end (create → accrue → mid-stream withdraw → pause → stranger rejected → expiry with no `resume()` auto-unfreezing → full principal → vault drained to exactly zero), plus `creditArrival` with no double charge. Real AUSD's identity, decimals, supply and EIP-712 permit domain are asserted against live state.

**Documented limit:** AUSD's balance mapping is not at a discoverable low storage slot, so neither forge-std's `deal` nor a 1024-slot scan can fund an account with it on a fork. AUSD-funded flows are therefore covered on testnet, where Agora's AUSD is the same bytecode. Stated in the test file rather than quietly skipped.

---

## Relationship to WinkPay — disclosure

Required by Metropolis T&Cs §4.1.4, stated plainly.

**WinkPay is my payments business.** It runs on Tempo. Tempo cannot do what I want next: per-second streaming is uneconomic on a ~1 s chain, and cross-border inbound cost 2.5% on small transfers. Monad can — 300 ms blocks, deterministic finality at ~600 ms, native Circle USDC, and CCTP V2 where Circle charges Monad 0 bps because its finality is already fast enough. So the cross-border streaming layer of the business is being built on Monad.

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

Both dependencies are pinned git submodules, not vendored copies, so the exact upstream commit is auditable from `.gitmodules`:

| Dependency | Version | Commit | Licence | Used for |
|---|---|---|---|---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | v5.4.0 | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` | MIT | `SafeERC20`, `ReentrancyGuardTransient`, `Ownable` |
| [forge-std](https://github.com/foundry-rs/forge-std) | v1.17.0 | `f3dae6e6ee381f25eb6a246f7da9b85c91a68219` | MIT / Apache-2.0 | test harness only |

Clone with `git clone --recurse-submodules`, or run `git submodule update --init --recursive` afterwards.

No other third-party code is included. All Solidity in `src/` is original to this submission.

## Licence

MIT — see `LICENSE`.
