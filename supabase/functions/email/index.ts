// Sends the queued emails (public.email_outbox) through the SMTP server in
// the function's secrets. The database calls this as soon as something is
// queued, and every minute to retry.
//
// Secrets: SMTP_HOST, SMTP_PORT (465 for TLS; Supabase blocks 25 and 587),
// SMTP_USER, SMTP_PASS, SMTP_FROM (for example "Wasla <no-reply@...>"), and
// SITE_URL for the download link.

import nodemailer from "npm:nodemailer@6.9.16";
import { rpc, serve } from "../_shared/db.ts";
import { format, type QueuedEmail } from "./format.ts";

const env = (k: string) => Deno.env.get(k)?.trim() || null;
const host = env("SMTP_HOST");
const from = env("SMTP_FROM") ?? env("SMTP_USER");
const site = env("SITE_URL");
const port = Number(env("SMTP_PORT") ?? "465");

const transport = host && from
  ? nodemailer.createTransport({
    host,
    port,
    secure: port === 465,
    auth: env("SMTP_USER") ? { user: env("SMTP_USER"), pass: env("SMTP_PASS") ?? "" } : undefined,
  })
  : null;

serve(async (key) => {
  if (!transport) {
    // Nothing can be sent yet; leave the queue alone.
    console.warn("SMTP_HOST and SMTP_FROM are not set");
    return { sent: 0 };
  }
  const started = Date.now();
  let sent = 0;
  while (Date.now() - started < 40_000) {
    const rows = await rpc<QueuedEmail[]>("claim_email_batch", { p_key: key, p_limit: 20 });
    if (!rows.length) break;
    const done: number[] = [];
    for (const q of rows) {
      const email = format(q, site);
      if (!email) {
        done.push(q.id);
        continue;
      }
      try {
        await transport.sendMail({ from, ...email });
        done.push(q.id);
        sent++;
      } catch (e) {
        // Tried again later, up to three times.
        console.error(e);
      }
    }
    await rpc("finish_email_batch", { p_key: key, p_ids: done });
  }
  return { sent };
});
