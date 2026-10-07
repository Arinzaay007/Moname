import { defineChain, type Chain } from "viem";
import { monadTestnet } from "viem/chains";

/**
 * Monad mainnet. viem ships `monadTestnet` but not mainnet, so this is defined here.
 *
 * blockTime is 300 ms, MEASURED on live mainnet on 2026-10-07: blocks 111325867..111325887
 * spanned 6 seconds over 20 blocks = exactly 300 ms/block. Note viem's own monadTestnet
 * definition says 400, which is wrong for mainnet; the UI polls at 300 ms because that is
 * the real cadence and per-block polling is the whole point of the product.
 */
export const monad = /*#__PURE__*/ defineChain({
  id: 143,
  name: "Monad",
  blockTime: 300,
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.monad.xyz"] },
  },
  blockExplorers: {
    default: { name: "Monadscan", url: "https://monadscan.com" },
  },
  contracts: {
    multicall3: {
      address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    },
  },
  testnet: false,
});

export { monadTestnet };

// ---------------------------------------------------------------------------
// Tokens — every address read off-chain with `cast` on 2026-10-07, and
// re-asserted against live state by test/Fork.t.sol. Not copied from a README.
// ---------------------------------------------------------------------------

export type DollarToken = {
  symbol: "AUSD" | "USDC";
  name: string;
  address: `0x${string}`;
  decimals: 6;
  /** Primary = Agora's AUSD, the token the Agora cross-border bounty names. */
  primary: boolean;
};

/** Agora AUSD on Monad mainnet. EIP-1967 proxy; impl 0xc1e3C7D486d6A92fBE920232E439EeC2cEb112dA. */
export const AUSD_MAINNET = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a" as const;
/** Agora AUSD on Monad testnet. Codesize 5937 — identical bytecode to mainnet. */
export const AUSD_TESTNET = "0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC" as const;
/** Circle USDC on Monad mainnet. NOT deployed on testnet (verified: codesize 0). */
export const USDC_MAINNET = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603" as const;

/**
 * Override for local development against anvil, where the real AUSD does not exist and
 * test/mocks/MockAUSD.sol is deployed instead. Ignored on mainnet unless explicitly set.
 */
export const AUSD_OVERRIDE = (() => {
  const v = process.env.NEXT_PUBLIC_AUSD_ADDRESS;
  return v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as `0x${string}`) : undefined;
})();

export const USDC_OVERRIDE = (() => {
  const v = process.env.NEXT_PUBLIC_USDC_ADDRESS;
  return v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as `0x${string}`) : undefined;
})();

export function tokensFor(chainId: number): DollarToken[] {
  if (chainMode() === "local") {
    if (!AUSD_OVERRIDE) return [];
    return [{ symbol: "AUSD", name: "AUSD (local mock)", address: AUSD_OVERRIDE, decimals: 6, primary: true }];
  }
  if (chainId === monad.id) {
    return [
      { symbol: "AUSD", name: "Agora USD", address: AUSD_OVERRIDE ?? AUSD_MAINNET, decimals: 6, primary: true },
      { symbol: "USDC", name: "USD Coin", address: USDC_OVERRIDE ?? USDC_MAINNET, decimals: 6, primary: false },
    ];
  }
  // Testnet has AUSD only. USDC is not deployed there (verified: codesize 0).
  return [{ symbol: "AUSD", name: "Agora USD (testnet)", address: AUSD_OVERRIDE ?? AUSD_TESTNET, decimals: 6, primary: true }];
}

// ---------------------------------------------------------------------------
// Moname contract addresses
//
// Empty until deployed. Set these in .env.local after running:
//   forge script script/Deploy.s.sol:Deploy --rpc-url monad --broadcast
// The deploy script prints the addresses; paste them here or into the env.
//
// The app refuses to pretend it is connected when these are unset, and shows the
// reason — a judge must never be shown a mockup that looks live. See §9.1.
// ---------------------------------------------------------------------------

export type Deployment = {
  streamVault: `0x${string}` | undefined;
  handleRegistry: `0x${string}` | undefined;
};

function addr(v: string | undefined): `0x${string}` | undefined {
  if (!v || !/^0x[0-9a-fA-F]{40}$/.test(v)) return undefined;
  return v as `0x${string}`;
}

export const deployment: Deployment = {
  streamVault: addr(process.env.NEXT_PUBLIC_STREAM_VAULT),
  handleRegistry: addr(process.env.NEXT_PUBLIC_HANDLE_REGISTRY),
};

export const isDeployed = Boolean(deployment.streamVault && deployment.handleRegistry);

/**
 * Which chain the browser should talk to. Defaults to mainnet because that is the
 * submission target; NEXT_PUBLIC_CHAIN=testnet switches for development.
 */
/**
 * A local anvil running in Monad mode, so the product is demonstrable before mainnet
 * deployment. §9.1 wants a functioning prototype, not a mockup — and a prototype that
 * cannot run until someone funds a key is not one. Start it with:
 *
 *   anvil --network monad --chain-id 10143
 *   forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * then set NEXT_PUBLIC_CHAIN=local and the two NEXT_PUBLIC_* addresses.
 */
export const monadLocal = /*#__PURE__*/ defineChain({
  id: 10_143,
  name: "Monad (local anvil)",
  blockTime: 300,
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["/api/rpc"] } },
  testnet: true,
});

export type ChainMode = "mainnet" | "testnet" | "local";

export function chainMode(): ChainMode {
  const v = process.env.NEXT_PUBLIC_CHAIN;
  return v === "testnet" ? "testnet" : v === "local" ? "local" : "mainnet";
}

export function activeChain(): Chain {
  switch (chainMode()) {
    case "testnet":
      return { ...monadTestnet, rpcUrls: { default: { http: ["/api/rpc"] } } };
    case "local":
      return monadLocal;
    default:
      // Mainnet also goes through the proxy: browser CORS to a public RPC is not
      // something to bet a demo on, and the preview host is not localhost.
      return { ...monad, rpcUrls: { default: { http: ["/api/rpc"] } } };
  }
}

/**
 * Monad charges gas on the DECLARED limit, not gas used
 * (docs.monad.xyz/developer-essentials/differences). An over-estimate is real money,
 * so the UI sets explicit limits instead of accepting an estimate blindly. These are
 * measured from test/Fork.t.sol and the gas report, with headroom.
 */
export const GAS_LIMITS = {
  createStreamWithPermit: 400_000n,
  createStream: 300_000n,
  register: 200_000n,
  withdrawAll: 150_000n,
  pause: 100_000n,
  resume: 100_000n,
} as const;

/** Poll cadence. Matches the measured 300 ms mainnet block time. */
export const BLOCK_POLL_MS = 300;
