# وصلة · Wasla

تطبيق تواصل داخلي للشركات: محادثات مرتبطة بالمشاريع، ملفات، نشرات، ومهام ومتابعة، في مساحات عمل متعددة (SaaS).

Internal team communication for companies: project-tagged chat, files, announcements, tasks and follow-up, across multiple workspaces.

## Stack

- **App:** Flutter (Android, iOS, and the web for the admin dashboard and paying)
- **Backend:** Supabase today (PostgreSQL + Row Level Security, Auth, Realtime, Storage, Edge Functions). Everything is plain PostgreSQL so it can move to a self-hosted server later.

## Layout

| Path | What |
| --- | --- |
| `app/` | The Flutter app (Arabic first, right to left, light and dark) |
| `supabase/migrations/` | Database schema, permissions (RLS) and actions (RPC), applied in order |
| `supabase/tests/` | Permission tests that run on a throwaway local PostgreSQL |
| `site/` | The website's landing page (Arabic at `/`, English at `/en/`) |
| `.github/workflows/` | Checks on every pull request, the database deploy and the website deploy |

## Run the app

```sh
cd app
flutter pub get
flutter run
```

It talks to the hosted Supabase project by default. To point it at another server (for example the future self-hosted one):

```sh
flutter run --dart-define=SUPABASE_URL=https://... --dart-define=SUPABASE_KEY=...
```

Checks: `flutter analyze` and `flutter test` inside `app/`.

To spare Actions minutes, the checks run on pull requests only (the app's when `app/` changes, the database's when `supabase/` changes), a new push to a pull request cancels the run for the push before it, and the Android test build runs only by hand. On main, only the website and database deploys run (each builds or tests what it ships).

The same app runs in a browser: `flutter run -d chrome`, or `flutter build web --release --no-web-resources-cdn` for files any web host can serve (the result is in `app/build/web`; add `--base-href /app/` when it is served from a folder).

### Try it on an Android phone

The **Android test build** workflow builds an APK on demand: Actions > Android test build > Run workflow, on any branch (it no longer runs on every change, to save Actions minutes). Open the run, download `wasla-android-N` under Artifacts, unzip it and install `app-release.apk` on the phone (Android asks to allow installing from that source once). Until the app's signing key is set up (see [The website](#the-website)), each build is signed with a throwaway key, so uninstall the previous test build first. iPhone builds wait for the Apple developer account.

Sign-in uses a 6-digit email code. In the Supabase dashboard (Authentication > Email Templates), both the **Confirm signup** template (first sign-in) and the **Magic Link** template (later sign-ins) must include `{{ .Token }}` so the code is in the email. Supabase's built-in email sender only reaches the project's team members, and on new free projects it also locks the templates to a link-only default. So connect an SMTP provider first (Authentication > Emails > SMTP Settings), then edit the two templates.

## Run the database tests

```sh
supabase/tests/run.sh
```

Needs PostgreSQL 15+ server binaries. The script starts a temporary server, stubs the bits of Supabase auth the migrations use, applies every migration and runs every `*_test.sql`.

## Deploy the database

When a change to `supabase/migrations/` lands on `main`, the **Deploy database** workflow runs the tests and then applies the new migrations to the hosted project with the Supabase CLI. It can also be started by hand from the Actions tab.

It needs two repository secrets under Settings > Secrets and variables > Actions:

- `SUPABASE_ACCESS_TOKEN`: a personal access token from supabase.com/dashboard/account/tokens
- `SUPABASE_DB_PASSWORD`: the database password of the project

## Joining a workspace

- An admin invites by email (and optionally straight into projects), then sends the invitation on from the app through WhatsApp, email or any other app; it carries the download link when the app is built with `--dart-define=SITE_URL=https://...` (in a browser, the site it is served from).
- Each invitation to an email is also emailed to that address, in the person's language, with the download link and the steps to accept. The Edge Function `email` sends the queue (`email_outbox`) through any SMTP server: add the repository secrets `SMTP_HOST`, `SMTP_PORT` (465; Supabase blocks 25 and 587), `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` (for example `Wasla <no-reply@your-domain>`) and the variable `SITE_URL`, then run the Deploy database workflow. The same mail account as the sign-in codes works. Without them nothing is emailed and the rest works as before.
- Instead of inviting one email at a time, an admin can turn on the workspace's join link (More > Join link): one eight-character code, shared as a link (`/app/?join=CODE`, kept through sign-in) or typed in under "I have a join code". It sends a request to join, or with "join without approval" lets people straight in as members (the admins are told). Only owners and admins see the code; renewing it stops the old one, and the plan's seats still count.
- Invitations, requests to join and their answers are notifications like any other: the invited person (as soon as they have an account), every owner and admin of the workspace for a request, the person asking for the answer, and the inviting admin when it is accepted. Once answered, withdrawn or cancelled, they count as read for everyone.
- Open ones show on top of the bell with Accept and Decline on them, as a banner on the home screen, in the workspace switcher and on the start page. Someone waiting for an answer moves into the workspace as soon as they are accepted.

## First steps

- Owners and admins of a new workspace get a **Get started** card on the home screen: a first project, the team invited (by email or the join link), attendance on, and a first announcement. It shows the next step only (all of them on asking), ticks each one when it is done anywhere in the app (`workspace_setup()`), and goes away once all are done or it is closed.

## Approvals

- **More > Waiting for your approval** gathers, for the workspace on screen, everything that waits for the signed-in person: requests to join (owners and admins), check-ins from outside a branch and attendance corrections (attendance managers), and tasks in review that they may close (their own, and every task in the projects they lead). Each is answered right there. A banner on the home screen and a count on More say when something is waiting.

## Management dashboard

- **More > Management dashboard** shows company owners every workspace of their companies, and workspace owners and admins the workspaces they run, side by side: people, open, late and in-review tasks, tasks done this week against the week before, project chat activity (messages and how many people wrote), today's attendance, and each project's progress. It comes from `management_overview()`, which counts and never reads: no message text, and private chats are not counted at all.

## My account and notification controls

- The picture in the top bar opens **My account**: one's name, quiet hours, Google, appearance, language and signing out. More keeps only the workspace's things.
- **Quiet hours** (for example 22:00 to 07:00, in the phone's time zone, kept up to date when it changes) keep everything off the phone; the bell and the app's counts still have it all.
- **Muting a chat** (8 hours, a week, or until unmuted) from the bell at the top of the chat keeps its messages off the phone; mentions still come through. Muted chats are marked in the list.
- Both are applied in `queue_push()`, where every phone notification is queued.

## Chats and files

- Every project has a group chat for its members. Private chats are between two people only: workspace owners and admins cannot read them, and a private message can be tagged with a project the two people share so it shows under that project.
- Photos and files go to the private Storage bucket `files` (50 MB each, counted against the plan's storage). The app opens them through links that expire after an hour. Files sent in a private chat stay visible only to its two people.
- New messages and read marks arrive live through Supabase Realtime (the `messages` and `conversation_reads` tables are in the `supabase_realtime` publication; what each person receives still follows the database permissions).
- Files deleted from a chat, a project or a task, and uploads that were never sent, are removed from storage the next night by the Edge Function `cleanup` (run by the `pg_cron` job `wasla-file-cleanup`), so they stop counting against the plan.

## Phone notifications

- New chat messages, announcements, and everything the bell shows (tasks, reminders, billing) reach the phones of the people concerned through Firebase Cloud Messaging, written in each phone's app language. Tapping one opens the chat, task or announcements it is about. They don't show while the app is open; the app updates live instead.
- The app registers its phone with `register_push_token` at every start and language change, and removes it on sign-out. Triggers queue a row in `push_outbox` per person with a phone; the Edge Function `push` sends them. The database calls it through `pg_net` as soon as something is queued, and the `pg_cron` job `wasla-push` retries every minute (three tries, nothing over an hour late).
- The functions prove themselves with the key in `push_config`; its `base_url` points at the hosted project's functions and must change when the database moves to its own server.
- Setup: the Android app's settings from Firebase's `google-services.json` are in `app/lib/push/firebase_options.dart` (Firebase project `wasla-a114f`), and the repository secret `FIREBASE_SERVICE_ACCOUNT` holds the service account JSON (Firebase > Project settings > Service accounts > Generate new private key). The Deploy database workflow hands it to the functions; run it again after adding or changing the secret. iPhones wait for the Apple developer account.

## Tasks and follow-up

- A task belongs to one project and goes to one or more of its members. Leads and admins assign anyone in the project; other members create tasks for themselves, and on an existing task only add or remove themselves.
- Tasks are private by default: only their creator, assignees and the project's leads and admins see them. A public task is visible to the whole project, but its comments stay with those people.
- Assignees move a task between new, in progress, on hold (with a reason) and review; only its creator or a lead closes or reopens it.
- Reminders go out a day and an hour before the due time by default, plus once when it passes and at any extra times the creator adds. They are sent by the `pg_cron` job `wasla-task-reminders`, which runs `process_task_reminders()` every minute. The migration creates the job where `pg_cron` is available (hosted Supabase) and skips it elsewhere.
- Notifications show under the bell on the home screen and on the phone (see Phone notifications).
- Tasks in an archived or closed project are read-only, leave My tasks and stop reminding; reopening the project schedules their reminders again.
- Deleting a task removes its attachments too and tells the people on it. Someone taken off a task is told as well.
- Each person can make 60 task changes a minute; saving a task unchanged doesn't count.

## Subscriptions and the admin dashboard

- Each workspace is on a plan (Free, Basic, Business, Enterprise) that sets its seats and storage. Prices are in US dollars a month per workspace. A company pays in its country's currency at the rate a platform admin sets for that country; every invoice keeps the rate it was issued at.
- Until online payment arrives, payment is by bank transfer: the company owner asks for a plan from **More > Subscription and billing**, a platform admin issues one invoice for the company with a line per workspace, and marks it paid when the money arrives. That puts each workspace on its plan for the months paid (paying again for the same plan adds to the time left; a different plan starts from that day).
- A week before paid time ends the owner is warned; a week after it ends the workspace goes back to the free plan. Nothing is deleted, but it takes no new members or files beyond the free limits. The `pg_cron` job `wasla-subscriptions` does this daily at 06:00 UTC.
- A platform admin can also put a workspace on a plan by hand, with or without an end date (a trial, the pilot company, an agreement paid outside the app).
- Platform admins are the people who run Wasla, not a company's admins. They see **More > Platform admin** in the app, and in a browser the dashboard is their first page. Add the first one in the Supabase SQL editor:

  ```sql
  insert into public.platform_admins (user_id)
  select id from auth.users where email = 'you@example.com';
  ```

## The website

The **Website** workflow publishes one site to the hosting account by FTP whenever the app or `site/` changes on `main`:

| Address | What |
| --- | --- |
| `/` and `/en/` | The landing page; its pricing table reads the offered plans and prices live (`public_plans()`, the only thing visitors can reach without signing in) |
| `/app/` | The web app |
| `/download/wasla.apk` | The latest Android app, always at the same link, with `version.json` beside it |

Setup, under Settings > Secrets and variables > Actions:

- Secrets `FTP_SERVER`, `FTP_USERNAME`, `FTP_PASSWORD` for the hosting account. If its FTP login doesn't open on the home folder, add the variable `FTP_DIR` with the site's folder as FTP sees it (default `public_html/`). FTPS is used; set the variable `FTP_PROTOCOL` to `ftp` only if the host has none. Turn on SSL for the domain first: the site sends every visitor to HTTPS.
- The Android app's signing key, made once: add the secret `ANDROID_KEY_PASSWORD` (a long password you keep), run the **Create Android signing key** workflow, download its `android-signing-key` artifact, and paste the contents of `ANDROID_KEYSTORE.txt` into a new secret `ANDROID_KEYSTORE`. Keep `wasla.p12` and the password safe: every update must be signed with this key, or phones refuse to install it. Until the key exists the site's download button says "coming soon".

Without the FTP secrets the built site is attached to the workflow run instead.

## Plan

1. Foundation: sign-up, workspaces, invites and join requests, roles, projects (done)
2. Chat and files: realtime chat tagged by project, files, announcements (done)
3. Tasks and follow-up: tasks, statuses, reminders, public tasks, status and follow-up screens (done)
4. Subscriptions: plans, exchange rates, company invoices, platform admin dashboard on the web, landing page with the download link (done)
5. Later: online payments (Paymob, Tap), reports, AI assistant, calls
