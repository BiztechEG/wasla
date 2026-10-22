import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { format, type QueuedEmail } from "./format.ts";

const invite: QueuedEmail = {
  id: 1,
  kind: "invite",
  to_email: "hoda@example.com",
  locale: "ar",
  data: {
    workspace: "Engineering",
    company: "Al Nour",
    inviter: "Mona",
    role: "member",
    expires_at: "2026-10-29T10:00:00Z",
  },
};

Deno.test("an invitation says who, where and how to accept, in Arabic by default", () => {
  const e = format(invite, "https://wasla.example/")!;
  assertEquals(e.to, "hoda@example.com");
  assertEquals(e.subject, "Mona يدعوك للانضمام إلى Engineering على وصلة");
  assertStringIncludes(e.text, "بدور عضو");
  assertStringIncludes(e.text, "1. حمّل تطبيق وصلة: https://wasla.example/#download");
  assertStringIncludes(e.text, "2. ادخل بهذا البريد نفسه: hoda@example.com");
  assertStringIncludes(e.text, "Engineering (Al Nour)");
  assertStringIncludes(e.text, "29");
  assertStringIncludes(e.html, 'dir="rtl"');
});

Deno.test("an invitation in English, without a site", () => {
  const e = format({ ...invite, locale: "en", data: { ...invite.data, role: "admin" } }, null)!;
  assertEquals(e.subject, "Mona invited you to join Engineering on Wasla");
  assertStringIncludes(e.text, "as admin");
  assertStringIncludes(e.text, "1. Get the Wasla app.\n");
  assert(!e.html.includes("<a "));
});

Deno.test("names are escaped in the HTML", () => {
  const e = format({ ...invite, data: { ...invite.data, inviter: "<b>Mona</b>" } }, null)!;
  assert(!e.html.includes("<b>Mona</b>"));
  assertStringIncludes(e.html, "&lt;b&gt;Mona&lt;/b&gt;");
});

const weekly: QueuedEmail = {
  id: 2,
  kind: "weekly_report",
  to_email: "boss@example.com",
  locale: "ar",
  data: {
    workspaces: [
      {
        workspace: "Engineering",
        done: 12,
        done_before: 8,
        open: 5,
        late: 2,
        review: 1,
        late_arrivals: 3,
      },
      {
        workspace: "<Site>",
        done: 1,
        done_before: 0,
        open: 2,
        late: 0,
        review: 0,
        late_arrivals: null,
      },
    ],
  },
};

Deno.test("the weekly report lists each workspace's week", () => {
  const e = format(weekly, "https://wasla.example")!;
  assertEquals(e.subject, "تقرير وصلة الأسبوعي");
  assertStringIncludes(e.text, "Engineering\n- أُنجزت 12 مهمة (مقابل 8 في الأسبوع السابق)");
  assertStringIncludes(e.text, "- 3 تأخير في الحضور");
  assertStringIncludes(e.text, "https://wasla.example/app/");
  // Attendance only where it is on.
  assertEquals(e.text.split("تأخير في الحضور").length, 2);
  assert(!e.html.includes("<Site>"));
});

Deno.test("the weekly report in English", () => {
  const e = format({ ...weekly, locale: "en" }, null)!;
  assertEquals(e.subject, "Your Wasla week");
  assertStringIncludes(e.text, "12 tasks done (8 the week before)");
  assert(!e.html.includes("<a "));
});
