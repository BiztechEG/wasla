import type { Outcome } from "./fcm.ts";
import type { Queued } from "./format.ts";

// Which queued notifications are finished, and which phones to forget.
// outcomes[i] is how sending rows[i] went (null: the person has no phone).
// A notification is finished unless it only failed for reasons that may pass,
// so a person with two phones isn't sent it twice when one of them fails.
export function settle(rows: Queued[], outcomes: (Outcome | null)[]) {
  const sent = new Set<number>();
  const retry = new Set<number>();
  const gone: string[] = [];
  rows.forEach((q, i) => {
    const o = outcomes[i];
    if (o === "sent") sent.add(q.id);
    if (o === "retry") retry.add(q.id);
    if (o === "gone" && q.token) gone.push(q.token);
  });
  const done = [...new Set(rows.map((q) => q.id))]
    .filter((id) => sent.has(id) || !retry.has(id));
  return { done, gone };
}
