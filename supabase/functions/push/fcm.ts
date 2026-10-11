// Sends to Firebase Cloud Messaging (HTTP v1) with the project's service
// account (the FIREBASE_SERVICE_ACCOUNT secret, the JSON file from Firebase).

import type { Shown } from "./format.ts";

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

export function readServiceAccount(raw: string | undefined): ServiceAccount | null {
  if (!raw) return null;
  const text = raw.trim().startsWith("{") ? raw : atob(raw.trim());
  const sa = JSON.parse(text) as ServiceAccount;
  return sa.project_id && sa.client_email && sa.private_key ? sa : null;
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemBody(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

let cached: { token: string; until: number } | null = null;

async function accessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.until > now + 60) return cached.token;

  const aud = sa.token_uri ?? "https://oauth2.googleapis.com/token";
  const enc = (o: unknown) => base64url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({ alg: "RS256", typ: "JWT" })}.${
    enc({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud,
      iat: now,
      exp: now + 3600,
    })
  }`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBody(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)),
  );
  const res = await fetch(aud, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${base64url(sig)}`,
    }),
  });
  if (!res.ok) throw new Error(`Google sign-in failed (${res.status}): ${await res.text()}`);
  const json = await res.json() as { access_token: string; expires_in: number };
  cached = { token: json.access_token, until: now + json.expires_in };
  return json.access_token;
}

// sent: delivered to Firebase. gone: the phone uninstalled the app or the
// token is no longer valid, so it should be forgotten. retry: try later.
export type Outcome = "sent" | "gone" | "retry";

// Whether Firebase's answer means the token itself is dead.
export function isGone(status: number, body: string): boolean {
  if (status === 404) return true;
  if (body.includes("UNREGISTERED") || body.includes("SENDER_ID_MISMATCH")) return true;
  return status === 400 && body.includes("registration token");
}

export async function send(sa: ServiceAccount, token: string, n: Shown): Promise<Outcome> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${await accessToken(sa)}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: n.title, body: n.body },
          data: n.data,
          android: {
            priority: "HIGH",
            notification: { tag: n.tag, sound: "default", channel_id: "wasla" },
          },
          apns: { payload: { aps: { sound: "default", "thread-id": n.tag } } },
        },
      }),
    },
  );
  if (res.ok) {
    await res.body?.cancel();
    return "sent";
  }
  const text = await res.text();
  if (isGone(res.status, text)) return "gone";
  console.error(`FCM ${res.status}: ${text.slice(0, 300)}`);
  return "retry";
}
