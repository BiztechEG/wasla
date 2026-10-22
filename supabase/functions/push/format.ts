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

const roles: Record<Locale, Record<string, string>> = {
  ar: { admin: "مسؤول", member: "عضو" },
  en: { admin: "admin", member: "member" },
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
    invite: (n, d, l) => `دعاك ${n} للانضمام بدور ${roles[l][d] ?? d}، اضغط للرد على الدعوة`,
    invite_accepted: (n) => `قَبِل ${n} دعوتك وانضم إلى مساحة العمل`,
    join_request: (n, d) => (d ? `${n} يطلب الانضمام: ${d}` : `${n} يطلب الانضمام إلى مساحة العمل`),
    request_accepted: () => "قُبل طلبك للانضمام، اضغط لفتح مساحة العمل",
    request_declined: () => "لم يُقبل طلبك للانضمام إلى مساحة العمل",
    attendance_in: () => "بدأت ورديتك ولم تسجّل حضورك بعد",
    attendance_out: () => "انتهت ورديتك ولم تسجّل انصرافك بعد",
    attendance_review: (
      n,
      d,
    ) => (d ? `سجّل ${n} حضوره من خارج الفرع: ${d}` : `سجّل ${n} حضوره من خارج الفرع`),
    attendance_fix: (n, d) => `طلب ${n} تصحيح حضور يوم ${d}`,
    attendance_accepted: (n, d) => `قَبِل ${n} تسجيل حضورك من خارج الفرع يوم ${d}`,
    attendance_rejected: (n, d) => `رفض ${n} تسجيل حضورك من خارج الفرع يوم ${d}`,
    attendance_fix_accepted: (n, d) => `قَبِل ${n} تصحيح يوم ${d}`,
    attendance_fix_rejected: (n, d) => `رفض ${n} تصحيح يوم ${d}`,
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
    invite: (n, d, l) => `${n} invited you to join as ${roles[l][d] ?? d}; tap to answer`,
    invite_accepted: (n) => `${n} accepted your invitation and joined`,
    join_request: (n, d) => (d ? `${n} asked to join: ${d}` : `${n} asked to join the workspace`),
    request_accepted: () => "Your request to join was accepted; tap to open the workspace",
    request_declined: () => "Your request to join wasn't accepted",
    attendance_in: () => "Your shift has started and you haven't checked in",
    attendance_out: () => "Your shift has ended and you haven't checked out",
    attendance_review: (
      n,
      d,
    ) => (d
      ? `${n} checked in away from the branch: ${d}`
      : `${n} checked in away from the branch`),
    attendance_fix: (n, d) => `${n} asked to correct ${d}`,
    attendance_accepted: (n, d) => `${n} accepted your check-in away from the branch on ${d}`,
    attendance_rejected: (n, d) => `${n} rejected your check-in away from the branch on ${d}`,
    attendance_fix_accepted: (n, d) => `${n} accepted your correction for ${d}`,
    attendance_fix_rejected: (n, d) => `${n} rejected your correction for ${d}`,
  },
};

const mentioned: Record<Locale, (name: string) => string> = {
  ar: (n) => `${n} أشار إليك`,
  en: (n) => `${n} mentioned you`,
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

  if (q.kind === "message" || q.kind === "mention") {
    const direct = data.direct === "true";
    // A mention always says who mentioned you, even in a private chat.
    const who = q.kind === "mention" && actor ? mentioned[l](actor) : actor;
    return {
      title: (direct ? actor : q.title) || appName[l],
      body: (direct && q.kind === "message") || !who ? body : `${who}: ${body}`,
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
    tag: data.task
      ? `task-${data.task}`
      : data.request
      ? `${q.kind}-${data.request}`
      : `${q.kind}-${ws}`,
    data,
  };
}
