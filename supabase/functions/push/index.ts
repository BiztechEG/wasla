// Sends the queued notifications (public.push_outbox): to phones through
// Firebase, and to browsers through Web Push. The database calls this as
// soon as something is queued, and every minute to retry.

import { rpc, serve } from "../_shared/db.ts";
import { readServiceAccount, send } from "./fcm.ts";
import { format, type Queued } from "./format.ts";
import { settle } from "./settle.ts";
import { newVapidKeys, sendWeb, type VapidKeys } from "./webpush.ts";

const account = readServiceAccount(Deno.env.get("FIREBASE_SERVICE_ACCOUNT"));

// Who the browsers' push services can reach about what is sent: the website,
// or else the backend.
const subject = Deno.env.get("SITE_URL")?.trim() || Deno.env.get("SUPABASE_URL") || "";

type KeyRow = { public_key: string; private_jwk: JsonWebKey };

// The key pair browsers' notifications are signed with, made on first use.
async function vapidKeys(key: string): Promise<VapidKeys> {
  let rows = await rpc<KeyRow[]>("web_push_keys", { p_key: key });
  if (!rows.length) {
    const made = await newVapidKeys();
    rows = await rpc<KeyRow[]>("save_web_push_keys", {
      p_key: key,
      p_public: made.publicKey,
      p_private: made.privateJwk,
    });
  }
  return { publicKey: rows[0].public_key, privateJwk: rows[0].private_jwk };
}

async function pool<T, R>(items: T[], size: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, items.length) }, worker));
  return out;
}

serve(async (key) => {
  const web = await vapidKeys(key);
  if (!account) console.warn("FIREBASE_SERVICE_ACCOUNT is not set: browsers only");

  const started = Date.now();
  let sent = 0;
  while (Date.now() - started < 40_000) {
    const rows = await rpc<Queued[]>("claim_push_batch", { p_key: key, p_limit: 300 });
    if (!rows.length) break;

    const outcomes = await pool(rows, 25, async (q) => {
      if (!q.token) return null;
      try {
        if (q.platform === "web") return await sendWeb(web, subject, q.token, format(q), q.locale);
        // Without Firebase's key phones wait, until the notification is too old.
        if (!account) return "retry" as const;
        return await send(account, q.token, format(q));
      } catch (e) {
        console.error(e);
        return "retry" as const;
      }
    });
    const { done, gone } = settle(rows, outcomes);
    await rpc("finish_push_batch", { p_key: key, p_ids: done, p_bad_tokens: gone });
    sent += outcomes.filter((o) => o === "sent").length;
  }
  return { sent };
});
