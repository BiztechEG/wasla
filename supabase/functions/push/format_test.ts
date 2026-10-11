import { assertEquals } from "jsr:@std/assert@1";
import { isGone } from "./fcm.ts";
import { format, type Queued } from "./format.ts";
import { settle } from "./settle.ts";

const base: Queued = {
  id: 1,
  token: "t1",
  locale: "ar",
  kind: "message",
  title: "Bridge",
  actor: "Sami",
  body: "Concrete at 7",
  data: { type: "chat", workspace: "w", conversation: "c", direct: false, task: null },
};

Deno.test("a project message names the project and the sender", () => {
  const n = format(base);
  assertEquals([n.title, n.body, n.tag], ["Bridge", "Sami: Concrete at 7", "chat-c"]);
  assertEquals(n.data, {
    type: "chat",
    workspace: "w",
    conversation: "c",
    direct: "false",
    kind: "message",
  });
});

Deno.test("a private message is titled with the sender", () => {
  const n = format({ ...base, title: "Sami", data: { ...base.data, direct: true } });
  assertEquals([n.title, n.body], ["Sami", "Concrete at 7"]);
});

Deno.test("task notifications use the app's wording in the phone's language", () => {
  const q = {
    ...base,
    kind: "status",
    title: "Order steel",
    body: "in_progress",
    data: { type: "task", workspace: "w", task: "t" },
  };
  assertEquals(format(q).body, "تغيّرت الحالة إلى قيد التنفيذ · Sami");
  assertEquals(format({ ...q, locale: "en" }).body, "Status changed to In progress · Sami");
  assertEquals(format({ ...q, kind: "overdue", actor: null }).body, "تجاوزت موعد التسليم");
  assertEquals(format(q).tag, "task-t");
});

Deno.test("billing and announcements", () => {
  const plan = {
    ...base,
    kind: "plan_ending",
    title: "Delta HQ",
    body: "Basic",
    actor: null,
    locale: "en",
    data: { type: "billing", workspace: "w" },
  };
  assertEquals(format(plan).body, "The Basic plan ends within a week; renew to keep it");
  const a = format({ ...base, kind: "announcement", title: "Delta HQ", body: "Closed Thursday" });
  assertEquals([a.title, a.body], ["نشرة · Delta HQ", "Sami: Closed Thursday"]);
});

Deno.test("dead tokens are told apart from passing failures", () => {
  assertEquals(isGone(404, "{}"), true);
  assertEquals(isGone(400, '{"errorCode":"UNREGISTERED"}'), true);
  assertEquals(isGone(400, "The registration token is not a valid FCM registration token"), true);
  assertEquals(isGone(400, "Invalid JSON payload"), false);
  assertEquals(isGone(503, "UNAVAILABLE"), false);
});

Deno.test("a notification is finished unless it only failed for passing reasons", () => {
  const rows = [
    { ...base, id: 1, token: "a" },
    { ...base, id: 1, token: "b" },
    { ...base, id: 2, token: "c" },
    { ...base, id: 3, token: "d" },
    { ...base, id: 4, token: null },
  ];
  const r = settle(rows, ["retry", "sent", "retry", "gone", null]);
  assertEquals(r.done, [1, 3, 4]);
  assertEquals(r.gone, ["d"]);
});
