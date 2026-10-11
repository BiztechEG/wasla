// What a phone notification says, in the phone's language. Mirrors the
// app's own wording (app/lib/l10n).

export type Locale = "ar" | "en";

export interface Queued {
  id: number;
  token: string | null;
  locale: string;
  kind: string;
  title: string | null;
  actor: string | null;
  body: string | null;
  data: Record<string, unknown>;
}

export interface Shown {
  title: string;
  body: string;
  // Notifications with the same tag replace each other on the phone.
  tag: string;
  data: Record<string, string>;
}

const statuses: Record<Locale, Record<string, string>> = {
  ar: {
    new: "جديدة",
    in_progress: "قيد التنفيذ",
    on_hold: "متوقفة",
    review: "للمراجعة",
    done: "منتهية",
  },
  en: {
    new: "New",
    in_progress: "In progress",
    on_hold: "On hold",
    review: "In review",
    done: "Done",
  },
};

const plans: Record<Locale, Record<string, string>> = {
  ar: { Free: "المجانية", Basic: "الأساسية", Business: "الأعمال", Enterprise: "المؤسسات" },
  en: { Free: "Free", Basic: "Basic", Business: "Business", Enterprise: "Enterprise" },
};

type Note = (name: string, detail: string, l: Locale) => string;

const notes: Record<Locale, Record<string, Note>> = {
  ar: {
    assigned: (n) => `مهمة جديدة لك من ${n}`,
    status: (n, d, l) => `تغيّرت الحالة إلى ${statuses[l][d] ?? d} · ${n}`,
    comment: (n) => `تعليق جديد من ${n}`,
    due_changed: (n) => `تغيّر موعد التسليم · ${n}`,
    nudge: (n) => `تذكير من ${n}`,
    due_soon: () => "موعد التسليم يقترب",
    overdue: () => "تجاوزت موعد التسليم",
    reminder: () => "تذكير بالمهمة",
    unassigned: (n) => `لم تعد مكلّفاً بهذه المهمة · ${n}`,
    deleted: (n) => `حُذفت المهمة · ${n}`,
    plan_request: (n, d, l) => `طلب ${n} خطة ${plans[l][d] ?? d}`,
    invoice: (_, d) => `صدرت فاتورة جديدة ${d} بانتظار الدفع`,
    plan_active: (_, d, l) => `فُعّلت خطة ${plans[l][d] ?? d}`,
    plan_ending: (_, d, l) => `تنتهي خطة ${plans[l][d] ?? d} خلال أسبوع، جدّد الاشتراك للاستمرار`,
    plan_expired: (_, d, l) => `انتهت خطة ${plans[l][d] ?? d} وانتقلت المساحة إلى الخطة المجانية`,
  },
  en: {
    assigned: (n) => `New task for you from ${n}`,
    status: (n, d, l) => `Status changed to ${statuses[l][d] ?? d} · ${n}`,
    comment: (n) => `New comment from ${n}`,
    due_changed: (n) => `Due date changed · ${n}`,
    nudge: (n) => `Reminder from ${n}`,
    due_soon: () => "Due soon",
    overdue: () => "Past its due date",
    reminder: () => "Task reminder",
    unassigned: (n) => `You were taken off this task · ${n}`,
    deleted: (n) => `Task deleted · ${n}`,
    plan_request: (n, d, l) => `${n} asked for the ${plans[l][d] ?? d} plan`,
    invoice: (_, d) => `New invoice ${d} is waiting for payment`,
    plan_active: (_, d, l) => `The ${plans[l][d] ?? d} plan is on`,
    plan_ending: (_, d, l) => `The ${plans[l][d] ?? d} plan ends within a week; renew to keep it`,
    plan_expired: (_, d, l) =>
      `The ${plans[l][d] ?? d} plan ran out, so the workspace is on the free plan`,
  },
};

const announcement: Record<Locale, string> = { ar: "نشرة", en: "Announcement" };
const appName: Record<Locale, string> = { ar: "وصلة", en: "Wasla" };

// FCM data values must be strings.
function strings(data: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(data)) {
    if (v !== null && v !== undefined) out[k] = String(v);
  }
  return out;
}

export function format(q: Queued): Shown {
  const l: Locale = q.locale === "en" ? "en" : "ar";
  const actor = q.actor?.trim() || "";
  const body = q.body ?? "";
  const data = strings({ ...q.data, kind: q.kind });
  const ws = data.workspace ?? "";

  if (q.kind === "message") {
    const direct = data.direct === "true";
    return {
      title: (direct ? actor : q.title) || appName[l],
      body: direct || !actor ? body : `${actor}: ${body}`,
      tag: `chat-${data.conversation ?? ws}`,
      data,
    };
  }
  if (q.kind === "announcement") {
    return {
      title: q.title ? `${announcement[l]} · ${q.title}` : announcement[l],
      body: actor ? `${actor}: ${body}` : body,
      tag: `announcement-${ws}`,
      data,
    };
  }
  const note = notes[l][q.kind];
  return {
    title: q.title || appName[l],
    body: note ? note(actor, body, l) : body,
    tag: data.task ? `task-${data.task}` : `${q.kind}-${ws}`,
    data,
  };
}
