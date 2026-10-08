# وصلة · Wasla

تطبيق تواصل داخلي للشركات: محادثات مرتبطة بالمشاريع، ملفات، نشرات، ومهام ومتابعة، في مساحات عمل متعددة (SaaS).

Internal team communication for companies: project-tagged chat, files, announcements, tasks and follow-up, across multiple workspaces.

## Stack

- **App:** Flutter (Android, iOS; web later)
- **Backend:** Supabase today (PostgreSQL + Row Level Security, Auth, Realtime, Storage, Edge Functions). Everything is plain PostgreSQL so it can move to a self-hosted server later.

## Layout

| Path | What |
| --- | --- |
| `app/` | The Flutter app (Arabic first, right to left, light and dark) |
| `supabase/migrations/` | Database schema, permissions (RLS) and actions (RPC), applied in order |
| `supabase/tests/` | Permission tests that run on a throwaway local PostgreSQL |
| `.github/workflows/` | Checks on every pull request, and the database deploy |

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

### Try it on an Android phone

The **Android test build** workflow builds an APK on every change to the app (and on demand from the Actions tab). Open the run, download `wasla-android-N` under Artifacts, unzip it and install `app-release.apk` on the phone (Android asks to allow installing from that source once). Each build is signed with a throwaway key, so uninstall the previous test build first. iPhone builds wait for the Apple developer account.

Sign-in uses a 6-digit email code. In the Supabase dashboard (Authentication > Email Templates), both the **Confirm signup** template (first sign-in) and the **Magic Link** template (later sign-ins) must include `{{ .Token }}` so the code is in the email. Supabase's built-in email sender only reaches the project's team members; connect an SMTP provider before inviting other people.

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

## Chats and files

- Every project has a group chat for its members. Private chats are between two people only: workspace owners and admins cannot read them, and a private message can be tagged with a project the two people share so it shows under that project.
- Photos and files go to the private Storage bucket `files` (50 MB each, counted against the plan's storage). The app opens them through links that expire after an hour. Files sent in a private chat stay visible only to its two people.
- New messages and read marks arrive live through Supabase Realtime (the `messages` and `conversation_reads` tables are in the `supabase_realtime` publication; what each person receives still follows the database permissions).
- Push notifications come later, once a Firebase project exists.

## Plan

1. Foundation: sign-up, workspaces, invites and join requests, roles, projects (done)
2. Chat and files: realtime chat tagged by project, files, announcements (done; push notifications pending Firebase)
3. Tasks and follow-up: tasks, statuses, reminders, public tasks, status and follow-up screens
4. Subscriptions: plans, exchange rates, company invoices, platform admin
5. Later: online payments, reports, AI assistant, calls, web app
