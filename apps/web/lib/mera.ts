import {
  createSecretVaultWithNewPasskey,
  createSecretVaultWithExistingPasskey,
  decryptSecretVaultWithPasskey,
  parseSecretVault,
  createSecp256k1SigningSession,
  isMeraError,
  type PasskeySecretVault,
  type Secp256k1SigningSession,
} from "@category-labs/mera";
import { toViemAccount } from "@category-labs/mera/viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import type { LocalAccount } from "viem";

/**
 * Moname's passkey layer — the on-chain half of the "One Passkey, Many Keys" model.
 *
 * ONE passkey unlocks THREE separate keys, each with a different power. The point of the
 * split is that the key which can move money is not the key that lives in page memory:
 *
 *   owner      funds streams, sets terms, appoints controllers. Vault created with
 *              createSecretVaultWithNewPasskey — this is the ceremony that makes the passkey.
 *   session    operates a live stream: pause / resume / cancel ONLY. Registered on-chain as
 *              a StreamVault controller, which cannot withdraw or change terms.
 *   receiving  the address that gets paid. Passed to HandleRegistry.registerTo, so the
 *              handle can resolve somewhere that is not the owner key at all.
 *
 * Mera's own docs note that vaults encrypted with one reused PRF output share an encryption
 * key, so each secret needs a fresh salt. createSecretVaultWith{New,Existing}Passkey both
 * generate a fresh random salt internally, so this module never manages salts itself.
 */

export type KeyRole = "owner" | "session" | "receiving";

export const KEY_ROLES: { role: KeyRole; label: string; can: string }[] = [
  { role: "owner", label: "Owner key", can: "fund streams, set terms, appoint controllers" },
  { role: "session", label: "Session key", can: "pause, resume, cancel — cannot move funds" },
  { role: "receiving", label: "Receiving key", can: "be paid; what @handle resolves to" },
];

const STORAGE_KEY = "moname.passkey.vaults.v1";

type VaultStore = Partial<Record<KeyRole, { vault: PasskeySecretVault; address: string }>>;

function readStore(): VaultStore {
  if (typeof window === "undefined") return {};
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as Record<string, { vault: unknown; address: string }>;
    const out: VaultStore = {};
    for (const role of ["owner", "session", "receiving"] as KeyRole[]) {
      const entry = parsed[role];
      if (entry?.vault && typeof entry.address === "string") {
        // parseSecretVault validates structure and drops unknown fields. Untrusted input
        // from localStorage should never be trusted blindly.
        out[role] = { vault: parseSecretVault(entry.vault), address: entry.address };
      }
    }
    return out;
  } catch {
    return {};
  }
}

function writeStore(store: VaultStore) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(store));
}

export function storedKeys(): { role: KeyRole; address: string }[] {
  const store = readStore();
  return (Object.keys(store) as KeyRole[]).map((role) => ({
    role,
    address: store[role]!.address,
  }));
}

export function hasPasskey(): boolean {
  return Boolean(readStore().owner);
}

/**
 * Relying party. WebAuthn requires HTTPS outside localhost and the id must match the host.
 *
 * Note Mera's two ceremonies take DIFFERENT shapes: creation takes
 * `rp: { id, name }` (createPasskeyWithPrfOutput.Options) while assertion takes a bare
 * `rpId: string` (getPasskeyPrfOutput.Options). Getting this wrong is a type error, not a
 * runtime one — which is why this file is typechecked before any UI is built on it.
 */
export function relyingParty(): { id: string; name: string } {
  const host = typeof window === "undefined" ? "localhost" : window.location.hostname;
  return { id: host, name: "Moname" };
}

/** Relying party id for assertion ceremonies (unlock, adding a derived key). */
export function relyingPartyId(): string {
  return relyingParty().id;
}

function newKeyBytes(): { privateKey: `0x${string}`; secret: Uint8Array; address: string } {
  const privateKey = generatePrivateKey();
  const account = privateKeyToAccount(privateKey);
  const secret = new Uint8Array(32);
  for (let i = 0; i < 32; i++) secret[i] = Number.parseInt(privateKey.slice(2 + i * 2, 4 + i * 2), 16);
  return { privateKey, secret, address: account.address };
}

/**
 * Creates the passkey and the owner key in one ceremony, then derives the session and
 * receiving keys under the SAME passkey. One prompt per key, one passkey total.
 */
export async function onboard(displayName: string): Promise<{ owner: string; session: string; receiving: string }> {
  const rp = relyingParty();
  const store: VaultStore = {};

  // 1. Owner key — this call creates the passkey itself.
  const ownerKey = newKeyBytes();
  const ownerVault = await createSecretVaultWithNewPasskey({
    rp,
    user: { name: displayName, displayName },
    secret: ownerKey.secret,
  });
  store.owner = { vault: ownerVault, address: ownerKey.address };

  // 2 + 3. Session and receiving keys, added under the existing passkey.
  for (const role of ["session", "receiving"] as KeyRole[]) {
    const k = newKeyBytes();
    const vault = await createSecretVaultWithExistingPasskey({
      rpId: rp.id,
      credential: ownerVault.credential,
      secret: k.secret,
    });
    store[role] = { vault, address: k.address };
  }

  writeStore(store);
  return {
    owner: store.owner!.address,
    session: store.session!.address,
    receiving: store.receiving!.address,
  };
}

export type UnlockedKey = {
  role: KeyRole;
  address: `0x${string}`;
  account: LocalAccount<"mera">;
  session: Secp256k1SigningSession;
  /** Zeroes the key material. After this, signing throws SESSION_ENDED — irreversibly. */
  end: () => void;
};

/**
 * Unlocks one key with a passkey prompt and returns a viem account backed by it.
 *
 * `toViemAccount` signs digests with the live session key, so signing itself never shows a
 * passkey prompt — only this unlock does. That is what makes a per-second streaming UI
 * usable: one prompt, then the session key signs freely until `end()`.
 */
export async function unlock(role: KeyRole): Promise<UnlockedKey> {
  const store = readStore();
  const entry = store[role];
  if (!entry) throw new Error(`No ${role} key stored. Onboard first.`);

  const secret = await decryptSecretVaultWithPasskey({ rpId: relyingPartyId(), vault: entry.vault });
  const session = createSecp256k1SigningSession({ privateKey: secret });
  const account = toViemAccount(session);

  return {
    role,
    address: account.address,
    account,
    session,
    end: () => session.end(),
  };
}

/**
 * Translates Mera's error codes into something a person can act on.
 *
 * PRF_UNAVAILABLE is the one that actually bites, and it is documented in Monad's own
 * Mera notes as "the most common setup failure": on desktop Chrome, only passkeys saved to
 * Google Password Manager return a PRF output. A passkey in the browser's local profile
 * throws PRF_UNAVAILABLE. Test on the exact machine you will demo on.
 */
export function explainMeraError(e: unknown): string {
  if (!isMeraError(e)) return e instanceof Error ? e.message : String(e);
  switch (e.code) {
    case "PRF_UNAVAILABLE":
      return "This passkey can't provide a PRF output. On desktop Chrome, only passkeys saved to Google Password Manager work — a passkey stored in the browser's local profile will fail here. Try again and choose Google Password Manager, or use a phone/security key.";
    case "PASSKEY_OPERATION_FAILED":
      return "The passkey prompt was cancelled or failed. Try again.";
    case "DECRYPT_FAILED":
      return "That passkey doesn't match this stored key. Use the passkey you created it with.";
    case "SESSION_ENDED":
      return "This signing session was ended. Unlock the key again.";
    case "VAULT_FORMAT_INVALID":
      return "Stored key data is corrupt. Clear site data and onboard again.";
    case "CRYPTO_UNAVAILABLE":
      return "WebAuthn/WebCrypto unavailable. This page needs HTTPS (or localhost) in a supported browser.";
    default:
      return `Mera error: ${e.code}`;
  }
}

/** WebAuthn needs a secure context. Called at startup so the UI can say why, not just fail. */
export function secureContextProblem(): string | null {
  if (typeof window === "undefined") return null;
  if (!window.isSecureContext) {
    return "Passkeys need a secure context. Load this page over HTTPS, or via localhost.";
  }
  if (typeof window.PublicKeyCredential === "undefined") {
    return "This browser does not expose WebAuthn, so passkeys cannot work here.";
  }
  return null;
}
