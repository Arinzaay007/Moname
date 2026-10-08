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
 *
 * ---------------------------------------------------------------------------
 * LAZY ONBOARDING — why signup is one prompt and not three
 * ---------------------------------------------------------------------------
 * Each Mera ceremony shows a user-verification prompt, and Mera documents that the
 * requirement "is not configurable": createSecretVaultWithNewPasskey shows one (two on
 * authenticators that do not evaluate PRF at creation), and every
 * createSecretVaultWithExistingPasskey shows one more.
 *
 * Creating all three keys up front therefore costs THREE or FOUR prompts at signup for
 * keys most users never touch. But a recipient needs exactly one of them to get paid:
 *
 *   receiving  needed at signup — it is what a handle resolves to
 *   owner      needed only to PAY someone
 *   session    needed only to pause / resume / cancel a stream
 *
 * So onboard() creates the passkey and the receiving key only, and ensureKey() creates
 * owner or session on first use. Signup drops from 3-4 prompts to 1-2.
 *
 * Mera does export no-ceremony primitives (createSecretVault, decryptSecretVault) that
 * would allow ONE prompt to key all three vaults, but they are not reachable: the package
 * root does not re-export them and the exports map blocks subpath imports, so using them
 * would mean reimplementing their AES-256-GCM vault format against undocumented internals.
 * Verified at runtime, not assumed. Not worth it for a payments product.
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

/** True once any key exists. Was owner-only, which broke when onboarding stopped
 *  creating the owner key first. */
export function hasPasskey(): boolean {
  const store = readStore();
  return Boolean(store.receiving || store.owner || store.session);
}

/** Whether one specific role has been created yet. Drives the UI's "not created yet"
 *  state so a user is never offered an unlock for a key that does not exist. */
export function hasKey(role: KeyRole): boolean {
  return Boolean(readStore()[role]);
}

/**
 * The credential behind whichever passkey already exists, read from any stored vault.
 * Every PasskeySecretVault carries its own credential metadata, so adding a later key
 * needs no separate record of the creation ceremony and no unexported helper.
 */
function existingCredential() {
  const store = readStore();
  for (const role of ["receiving", "owner", "session"] as KeyRole[]) {
    const entry = store[role];
    if (entry?.vault?.credential) return entry.vault.credential;
  }
  return undefined;
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
 * Creates the passkey and the RECEIVING key only. One ceremony, so one
 * user-verification prompt (two on authenticators that do not evaluate PRF at creation).
 *
 * The owner and session keys are created on first use by ensureKey(). Deliberately not
 * created here: a recipient who only ever gets paid never needs them, and minting keys
 * nobody asked for costs prompts and adds material to lose.
 *
 * The receiving key is NOT returned unlocked. It can move money out of a stream, and the
 * point of the three-key split is that a money-moving key is not silently live in page
 * memory from the moment of signup.
 */
export async function onboard(displayName: string): Promise<{ receiving: string }> {
  const rp = relyingParty();
  const k = newKeyBytes();

  const vault = await createSecretVaultWithNewPasskey({
    rp,
    user: { name: displayName, displayName },
    secret: k.secret,
  });

  const store = readStore();
  store.receiving = { vault, address: k.address };
  writeStore(store);

  return { receiving: k.address };
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
 * Creates a key that does not exist yet, under the passkey that already does.
 * One user-verification prompt. Returns the address; the key is not left live.
 */
export async function addKey(role: KeyRole): Promise<string> {
  const store = readStore();
  if (store[role]) return store[role]!.address; // already exists — no prompt at all

  const credential = existingCredential();
  if (!credential) throw new Error("No passkey yet. Create one first.");

  const k = newKeyBytes();
  const vault = await createSecretVaultWithExistingPasskey({
    rpId: relyingPartyId(),
    credential,
    secret: k.secret,
  });
  store[role] = { vault, address: k.address };
  writeStore(store);
  return k.address;
}

/**
 * Get a role's key usable, costing EXACTLY ONE prompt either way.
 *
 * If the vault already exists, decrypt it (one assertion ceremony). If it does not,
 * create it — and because the private key was just generated locally and is still in
 * memory, return it live instead of spending a SECOND ceremony decrypting a vault we
 * wrote a moment ago.
 *
 * That is a deliberate trade against the "money-moving keys are not live in page memory"
 * rule above: the caller has just explicitly asked to use this key, and the session is
 * ended by the caller's cleanup. One prompt instead of two is the difference between
 * onboarding that feels like an email signup and onboarding that does not.
 */
export async function ensureKey(role: KeyRole): Promise<UnlockedKey> {
  const store = readStore();
  if (store[role]) return unlock(role);

  const credential = existingCredential();
  if (!credential) throw new Error("No passkey yet. Create one first.");

  const k = newKeyBytes();
  const vault = await createSecretVaultWithExistingPasskey({
    rpId: relyingPartyId(),
    credential,
    secret: k.secret,
  });
  store[role] = { vault, address: k.address };
  writeStore(store);

  // Same construction as unlock(), but from the key just generated rather than from a
  // decrypted one — which is what saves the second ceremony.
  const session = createSecp256k1SigningSession({ privateKey: k.secret });
  const account = toViemAccount(session);
  return { role, address: account.address, account, session, end: () => session.end() };
}

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
  if (!entry) throw new Error(`No ${role} key yet — call ensureKey("${role}") to create it under your existing passkey.`);

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
