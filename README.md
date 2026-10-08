# وصلة · Wasla

تطبيق تواصل داخلي للشركات: محادثات مرتبطة بالمشاريع، ملفات، نشرات، ومهام ومتابعة، في مساحات عمل متعددة (SaaS).

Internal team communication for companies: project-tagged chat, files, announcements, tasks and follow-up, across multiple workspaces.

## Stack

- **App:** Flutter (Android, iOS; web later)
- **Backend:** Supabase today (PostgreSQL + Row Level Security, Auth, Realtime, Storage, Edge Functions). Everything is plain PostgreSQL so it can move to a self-hosted server later.

## Layout

| Path | What |
| --- | --- |
| `supabase/migrations/` | Database schema, permissions (RLS) and actions (RPC), applied in order |
| `supabase/tests/` | Permission tests that run on a throwaway local PostgreSQL |

## Run the database tests

```sh
supabase/tests/run.sh
```

Needs PostgreSQL 15+ server binaries. The script starts a temporary server, stubs the bits of Supabase auth the migrations use, applies every migration and runs every `*_test.sql`.

## Plan

1. Foundation: sign-up, workspaces, invites and join requests, roles, projects
2. Chat and files: realtime chat tagged by project, files, announcements, notifications
3. Tasks and follow-up: tasks, statuses, reminders, public tasks, status and follow-up screens
4. Subscriptions: plans, exchange rates, company invoices, platform admin
5. Later: online payments, reports, AI assistant, calls, web app
