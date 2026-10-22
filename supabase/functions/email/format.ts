// What an email says, in the reader's language. Mirrors the app's wording
// (app/lib/l10n).

export type Locale = "ar" | "en";

export interface QueuedEmail {
  id: number;
  kind: string;
  to_email: string;
  locale: string;
  data: Record<string, unknown>;
}

export interface Email {
  to: string;
  subject: string;
  text: string;
  html: string;
}

const roles: Record<Locale, Record<string, string>> = {
  ar: { admin: "مسؤول", member: "عضو" },
  en: { admin: "admin", member: "member" },
};

function escape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function day(iso: unknown, l: Locale): string {
  const d = typeof iso === "string" ? new Date(iso) : null;
  if (!d || isNaN(d.getTime())) return "";
  // Western digits in both languages, as in the app.
  return d.toLocaleDateString(l === "ar" ? "ar-EG-u-nu-latn" : "en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "Africa/Cairo",
  });
}

/// An invitation: who invited whom to which workspace, and the three steps
/// to accept it. [site] is the website, for the download link.
export function inviteEmail(q: QueuedEmail, site: string | null): Email {
  const l: Locale = q.locale === "en" ? "en" : "ar";
  const s = (k: string) => String(q.data[k] ?? "").trim();
  const workspace = s("workspace");
  const company = s("company");
  const inviter = s("inviter") || (l === "ar" ? "مسؤول فريقك" : "Your team's admin");
  const role = roles[l][s("role")] ?? s("role");
  const until = day(q.data.expires_at, l);
  const base = site?.replace(/\/+$/, "") || null;
  const download = base ? `${base}/#download` : null;
  const web = base ? `${base}/app/` : null;
  const where = company && company !== workspace ? `${workspace} (${company})` : workspace;

  const t = l === "ar"
    ? {
      subject: `${inviter} يدعوك للانضمام إلى ${workspace} على وصلة`,
      intro: `دعاك ${inviter} للانضمام إلى مساحة العمل ${where} على وصلة بدور ${role}.`,
      steps: [
        download ? `حمّل تطبيق وصلة: ${download}` : "حمّل تطبيق وصلة.",
        `ادخل بهذا البريد نفسه: ${q.to_email}`,
        "ستجد الدعوة بانتظارك، اضغط «قبول».",
      ],
      webLine: web ? `أو افتحه من المتصفح: ${web}` : "",
      until: until ? `الدعوة صالحة حتى ${until}.` : "",
      ignore: "إذا لم تكن تتوقع هذه الدعوة فتجاهل هذا البريد.",
      button: "حمّل وصلة",
    }
    : {
      subject: `${inviter} invited you to join ${workspace} on Wasla`,
      intro: `${inviter} invited you to join the ${where} workspace on Wasla as ${role}.`,
      steps: [
        download ? `Get the Wasla app: ${download}` : "Get the Wasla app.",
        `Sign in with this same email: ${q.to_email}`,
        "Your invitation will be waiting; tap Accept.",
      ],
      webLine: web ? `Or open it in a browser: ${web}` : "",
      until: until ? `The invitation is valid until ${until}.` : "",
      ignore: "If you weren't expecting this, you can ignore this email.",
      button: "Get Wasla",
    };

  const text = [
    t.intro,
    "",
    ...t.steps.map((step, i) => `${i + 1}. ${step}`),
    ...(t.webLine ? ["", t.webLine] : []),
    ...(t.until ? ["", t.until] : []),
    "",
    t.ignore,
  ].join("\n");

  const dir = l === "ar" ? "rtl" : "ltr";
  const align = l === "ar" ? "right" : "left";
  const html = `<!doctype html>
<html lang="${l}" dir="${dir}"><body style="margin:0;background:#f3f5f4;font-family:Tahoma,Arial,sans-serif;color:#17201f">
<div style="max-width:520px;margin:0 auto;padding:24px 16px">
<div style="background:#fff;border-radius:16px;padding:24px;text-align:${align}">
<div style="font-size:22px;font-weight:bold;color:#0F6E6A;margin-bottom:12px">${
    l === "ar" ? "وصلة" : "Wasla"
  }</div>
<p style="font-size:16px;line-height:1.7;margin:0 0 16px">${escape(t.intro)}</p>
<ol style="font-size:15px;line-height:1.8;margin:0 0 16px;padding-${align}:20px">${
    t.steps.map((step) => `<li>${escape(step)}</li>`).join("")
  }</ol>
${
    download
      ? `<p style="margin:0 0 16px"><a href="${
        escape(download)
      }" style="display:inline-block;background:#0F6E6A;color:#fff;text-decoration:none;padding:12px 22px;border-radius:12px;font-weight:bold">${t.button}</a></p>`
      : ""
  }
${
    t.webLine
      ? `<p style="font-size:14px;color:#55615f;margin:0 0 8px">${escape(t.webLine)}</p>`
      : ""
  }
${t.until ? `<p style="font-size:14px;color:#55615f;margin:0 0 8px">${escape(t.until)}</p>` : ""}
<p style="font-size:13px;color:#7a8583;margin:16px 0 0">${escape(t.ignore)}</p>
</div></div></body></html>`;

  return { to: q.to_email, subject: t.subject, text, html };
}

/// The weekly report: each workspace's week in numbers, and a link to the
/// dashboard.
export function weeklyEmail(q: QueuedEmail, site: string | null): Email {
  const l: Locale = q.locale === "en" ? "en" : "ar";
  const rows = Array.isArray(q.data.workspaces)
    ? q.data.workspaces as Record<string, unknown>[]
    : [];
  const n = (w: Record<string, unknown>, k: string) => Number(w[k] ?? 0);
  const base = site?.replace(/\/+$/, "") || null;
  const web = base ? `${base}/app/` : null;
  const t = l === "ar"
    ? {
      subject: "تقرير وصلة الأسبوعي",
      intro: "هذا ما جرى في فرقك الأسبوع الماضي:",
      lines: (w: Record<string, unknown>) => [
        `أُنجزت ${n(w, "done")} مهمة (مقابل ${n(w, "done_before")} في الأسبوع السابق)`,
        `${n(w, "open")} مفتوحة، منها ${n(w, "late")} متأخرة`,
        `${n(w, "review")} بانتظار المراجعة`,
        ...(w.late_arrivals == null ? [] : [`${n(w, "late_arrivals")} تأخير في الحضور`]),
      ],
      open: "افتح لوحة الإدارة",
      off: "لإيقاف هذا التقرير: حسابي ← التقرير الأسبوعي.",
    }
    : {
      subject: "Your Wasla week",
      intro: "Here is how your teams did last week:",
      lines: (w: Record<string, unknown>) => [
        `${n(w, "done")} tasks done (${n(w, "done_before")} the week before)`,
        `${n(w, "open")} open, ${n(w, "late")} of them late`,
        `${n(w, "review")} waiting for review`,
        ...(w.late_arrivals == null ? [] : [`${n(w, "late_arrivals")} late arrivals`]),
      ],
      open: "Open the dashboard",
      off: "To stop this report: My account > Weekly report.",
    };
  const name = (w: Record<string, unknown>) => String(w.workspace ?? "");

  const text = [
    t.intro,
    ...rows.flatMap((w) => ["", name(w), ...t.lines(w).map((line) => `- ${line}`)]),
    ...(web ? ["", `${t.open}: ${web}`] : []),
    "",
    t.off,
  ].join("\n");

  const dir = l === "ar" ? "rtl" : "ltr";
  const align = l === "ar" ? "right" : "left";
  const html = `<!doctype html>
<html lang="${l}" dir="${dir}"><body style="margin:0;background:#f3f5f4;font-family:Tahoma,Arial,sans-serif;color:#17201f">
<div style="max-width:520px;margin:0 auto;padding:24px 16px">
<div style="background:#fff;border-radius:16px;padding:24px;text-align:${align}">
<div style="font-size:22px;font-weight:bold;color:#0F6E6A;margin-bottom:12px">${
    l === "ar" ? "وصلة" : "Wasla"
  }</div>
<p style="font-size:16px;line-height:1.7;margin:0 0 8px">${escape(t.intro)}</p>
${
    rows.map((w) =>
      `<h3 style="font-size:16px;margin:16px 0 6px;color:#0F6E6A">${escape(name(w))}</h3>
<ul style="font-size:15px;line-height:1.8;margin:0;padding-${align}:20px">${
        t.lines(w).map((line) => `<li>${escape(line)}</li>`).join("")
      }</ul>`
    ).join("\n")
  }
${
    web
      ? `<p style="margin:20px 0 0"><a href="${
        escape(web)
      }" style="display:inline-block;background:#0F6E6A;color:#fff;text-decoration:none;padding:12px 22px;border-radius:12px;font-weight:bold">${t.open}</a></p>`
      : ""
  }
<p style="font-size:13px;color:#7a8583;margin:16px 0 0">${escape(t.off)}</p>
</div></div></body></html>`;

  return { to: q.to_email, subject: t.subject, text, html };
}

export function format(q: QueuedEmail, site: string | null): Email | null {
  if (q.kind === "invite") return inviteEmail(q, site);
  if (q.kind === "weekly_report") return weeklyEmail(q, site);
  return null;
}
