# Wasla app

Flutter app for Android and iOS. See the root README for how to run it.

| Path | What |
| --- | --- |
| `lib/app.dart` | App setup and the gate that picks the first screen |
| `lib/data/` | Models and the backend interface (`WaslaApi`) with its Supabase implementation |
| `lib/state/` | Riverpod providers and device settings (theme, language) |
| `lib/ui/` | Screens |
| `lib/l10n/` | Arabic (template) and English strings |
| `test/` | Widget tests against an in-memory fake backend |

Font: IBM Plex Sans Arabic, under the SIL Open Font License (`assets/fonts/OFL.txt`).
