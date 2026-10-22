// Sends desktop notifications to browsers (Web Push): the message is
// encrypted for the browser (RFC 8291, aes128gcm) and the request signed
// with the function's own key pair (VAPID, RFC 8292). WebCrypto does it all.
import type { Outcome } from "./fcm.ts";
import type { Shown } from "./format.ts";

// Bytes in an ordinary ArrayBuffer, as WebCrypto takes them.
export type Bytes = Uint8Array<ArrayBuffer>;

export interface VapidKeys {
  // The uncompressed P-256 point, base64url: what browsers subscribe with.
  publicKey: string;
  privateJwk: JsonWebKey;
}

// A browser's push subscription, as the app registers it.
export interface Subscription {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}

export function b64url(bytes: Bytes): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64url(text: string): Bytes {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64 + "=".repeat((4 - b64.length % 4) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function concat(...parts: Bytes[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

const text = (s: string) => new TextEncoder().encode(s);

async function hmac(key: Bytes, data: Bytes): Promise<Bytes> {
  const k = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

// HKDF with one block of output, which is all Web Push needs.
async function hkdf(salt: Bytes, ikm: Bytes, info: Bytes, length: number) {
  const prk = await hmac(salt, ikm);
  return (await hmac(prk, concat(info, new Uint8Array([1])))).slice(0, length);
}

export async function newVapidKeys(): Promise<VapidKeys> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return {
    publicKey: b64url(raw),
    privateJwk: await crypto.subtle.exportKey("jwk", pair.privateKey),
  };
}

// The Authorization header: a JWT for the push service's origin, signed
// with the private key, and the public key.
export async function vapidHeader(
  keys: VapidKeys,
  endpoint: string,
  subject: string,
  now = Math.floor(Date.now() / 1000),
): Promise<string> {
  const enc = (o: unknown) => b64url(text(JSON.stringify(o)));
  const unsigned = `${enc({ typ: "JWT", alg: "ES256" })}.${
    enc({ aud: new URL(endpoint).origin, exp: now + 12 * 3600, sub: subject })
  }`;
  const key = await crypto.subtle.importKey(
    "jwk",
    keys.privateJwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  // WebCrypto's signature is already r || s, as JWTs want it.
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, text(unsigned)),
  );
  return `vapid t=${unsigned}.${b64url(sig)}, k=${keys.publicKey}`;
}

// The message encrypted for one browser, as the request body.
export async function encrypt(
  sub: Subscription,
  payload: Bytes,
  // Given only by tests, to compare with the RFC's example.
  fixed?: { salt: Bytes; local: CryptoKeyPair },
): Promise<Bytes> {
  const uaPublic = unb64url(sub.keys.p256dh);
  const authSecret = unb64url(sub.keys.auth);
  const salt = fixed?.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const local = fixed?.local ?? await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  );
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", local.publicKey));
  const theirs = await crypto.subtle.importKey(
    "raw",
    uaPublic,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: theirs }, local.privateKey, 256),
  );
  const ikm = await hkdf(
    authSecret,
    shared,
    concat(text("WebPush: info\0"), uaPublic, asPublic),
    32,
  );
  const cek = await hkdf(salt, ikm, text("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, text("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  // One record: the message and the last-record delimiter.
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce },
      key,
      concat(payload, new Uint8Array([2])),
    ),
  );
  const header = new Uint8Array(16 + 4 + 1);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096);
  header[20] = asPublic.length;
  return concat(header, asPublic, sealed);
}

export function readSubscription(token: string): Subscription | null {
  try {
    const s = JSON.parse(token) as Subscription;
    return s?.endpoint?.startsWith("https://") && s.keys?.p256dh && s.keys?.auth ? s : null;
  } catch {
    return null;
  }
}

// What the browser's service worker gets.
export function webPayload(n: Shown, locale: string): Bytes {
  return text(JSON.stringify({ title: n.title, body: n.body, tag: n.tag, data: n.data, locale }));
}

export async function sendWeb(
  keys: VapidKeys,
  subject: string,
  token: string,
  n: Shown,
  locale: string,
): Promise<Outcome> {
  const sub = readSubscription(token);
  if (!sub) return "gone";
  const res = await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      Authorization: await vapidHeader(keys, sub.endpoint, subject),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      // Kept for a day while the computer is off; chat goes first.
      TTL: "86400",
      Urgency: "high",
    },
    body: await encrypt(sub, webPayload(n, locale)),
  });
  await res.body?.cancel();
  if (res.ok) return "sent";
  // The browser unsubscribed, the subscription expired, or it was made
  // with another key.
  if (res.status === 404 || res.status === 410 || res.status === 403) return "gone";
  console.error(`Web Push ${res.status} from ${new URL(sub.endpoint).host}`);
  return "retry";
}
