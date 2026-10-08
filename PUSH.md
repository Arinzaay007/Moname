# Pushing Moname to GitHub

The repo must be **public**, and must stay public throughout and after the hackathon
(§7.2). It carries an MIT `LICENSE` and the attribution §4.1 requires.

I cannot push from the sandbox — there is no GitHub connector and no credentials here.
Two routes; **Route A is recommended** because it never puts a secret in a chat log.

---

## Route A — clone the bundle on your own machine (recommended)

### 1. Create an empty public repo

On GitHub, under `Arinzaay007`, create **`moname`**:

- Public
- **Do not** initialise with a README, `.gitignore`, or licence — the bundle already has all three, and an initial commit on GitHub would create a divergent history you then have to force-push over.

### 2. Download the bundle

From the workspace, download:

```
moname-backup/moname.bundle
```

It is 5.72 MB and contains the complete history — 7 commits, 947 files. Verified with
`git bundle verify` ("The bundle records a complete history") and by cloning it in a clean
directory.

### 3. Clone it and push

```bash
git clone /path/to/moname.bundle moname
cd moname

# point origin at GitHub instead of the bundle file
git remote set-url origin https://github.com/Arinzaay007/moname.git

# sanity check before pushing: should print 7
git rev-list --count HEAD

git push -u origin main
```

### 4. Verify on GitHub

- 7 commits, oldest `2b16b53` (2026-10-07 12:28 UTC), newest `e9473a8`
- `LICENSE` present, MIT
- `README.md` renders, including the "Third-party code" and "Relationship to WinkPay — disclosure" sections
- **`apps/web/.env.local` is absent** — it is gitignored and was confirmed not tracked

---

## Route B — let me push it

Create a **fine-grained** personal access token scoped to *only* the `moname` repo, with
Contents: Read and write. Paste it here and I will push, then you revoke it immediately.

Tradeoff, stated plainly: the token passes through this chat. Route A avoids that entirely,
which is why it is the recommendation. §5.3 of the rules also says never to commit keys or
secrets — a token in chat is not a commit, but it is still a credential exposed somewhere it
does not need to be.

---

## Do not do these

- **Do not squash or rebase the history.** §4.1 grades commit history covering the build
  window. Seven commits over two days is the real record.
- **Do not back-date anything.** §10.1 disqualifies for false or misleading information.
  The existing dates are genuine and in order; leave them.
- **Do not rename the commit messages that say "MonPay".** Two of them predate the rename to
  Moname. That is accurate history — the project *was* called MonPay at that commit, and
  `0b8fec6` is the rename. Rewriting them would misrepresent the sequence.

---

## Known history caveat, disclosed rather than hidden

One commit was lost to a sandbox git wipe and its work is folded into `0b8fec6` (the rename
commit) instead of standing alone. The **files are all present and correct**; only the
granularity is coarser than it should be. Nothing was fabricated and nothing was back-dated.

This is the third git incident caused by the sandbox wiping `.git` between tool calls, and it
is the reason pushing to GitHub is urgent rather than merely a checklist item. Once the repo
is on GitHub it becomes the source of truth and this failure mode stops.

---

## After the push

1. Put the repo URL in the submission form.
2. Tell me and I will add it to the README header.
3. Next blocker is the mainnet deploy — **0.495385002 MON** (2,452,401 gas at a 100 gwei base
   fee) for both contracts. That needs a funded key, which is yours to provide.

## Building after cloning

Neither `node_modules` nor forge's `out/` is committed — both are reproducible:

```bash
# contracts
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge build
forge test --network monad          # expect 58 passing

# web app
cd apps/web && npm install && npm run dev
```

Dependencies are **vendored** into `lib/`, so there is no `git submodule update --init` step
and no network fetch needed to build the contracts.

For a full local demo without touching mainnet:

```bash
anvil --network monad --chain-id 10143 --block-time 1   # terminal 1
bash tools/local-dev.sh                                 # terminal 2: deploys, funds the relayer, seeds
cd apps/web && npm run dev                              # terminal 3
bash tools/test-relay.sh                                # proves the gasless path end to end
```
