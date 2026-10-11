// Sends the queued phone notifications (public.push_outbox). The database
// calls this as soon as something is queued, and every minute to retry.

import { rpc, serve } from "../_shared/db.ts";
import { readServiceAccount, send } from "./fcm.ts";
import { format, type Queued } from "./format.ts";
import { settle } from "./settle.ts";

const account = readServiceAccount(Deno.env.get("FIREBASE_SERVICE_ACCOUNT"));

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
  if (!account) {
    // Without Firebase's key nothing can be sent; leave the queue alone.
    console.warn("FIREBASE_SERVICE_ACCOUNT is not set");
    return { sent: 0 };
  }

  const started = Date.now();
  let sent = 0;
  while (Date.now() - started < 40_000) {
    const rows = await rpc<Queued[]>("claim_push_batch", { p_key: key, p_limit: 300 });
    if (!rows.length) break;

    const outcomes = await pool(rows, 25, async (q) => {
      if (!q.token) return null;
      try {
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
