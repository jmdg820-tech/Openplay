# OpenPlay

OpenPlay is an MVP client for finding, hosting, and joining open-play
pickleball sessions: discover nearby sessions, join as a registered user or
as a guest, manage waitlists/promotions, and let organizers/venue staff run
their own sessions.

## Architecture

- **Client**: Flutter (this `app/` directory) — web, Windows desktop, and
  Android targets are scaffolded (see `flutter doctor` for which are
  actually buildable on your machine).
- **Backend**: Supabase (Postgres + Auth + Realtime + PostgREST). All
  business logic, authorization, and privacy rules live in the database --
  in Postgres functions (RPCs) and Row Level Security policies -- not in
  the client. The client only ever calls the approved RPCs and reads the
  public/RLS-scoped tables; see `docs/openplay-v3-architecture.md` for the
  full schema/RPC/security design.
- **Database migrations**: `supabase/migrations/` (repo root), applied in
  numeric order.

## Project structure

```
app/
  lib/
    config.dart        Runtime Supabase URL/key (via --dart-define, never hardcoded)
    main.dart           App entry point, auth gate
    models/             Plain data classes matching RPC/table response shapes
    screens/             UI screens
    services/            openplay_api.dart -- the app's only point of contact
                          with Supabase (RPCs + public table reads)
    utils/               Pure helper logic (validation, error mapping, geo parsing)
    widgets/              Shared widgets
  test/                 Flutter unit/widget tests
supabase/migrations/    Database schema, RLS, RPCs (repo root)
test/                   Node-based DB regression/security test harness (repo root)
docs/                   Architecture documentation (repo root)
```

## Development prerequisites

- Flutter SDK, stable channel (developed against 3.47.3) -- run `flutter doctor`
  to confirm which build targets (web/Windows/Android) are actually usable
  on your machine; not all are required for basic development.
- Node.js (for the `test/` DB regression harness).
- A local PostgreSQL 17 instance if you want to run the DB regression suite
  (see below) -- not required just to run the Flutter app against a real
  Supabase project.
- A Supabase project (URL + anon/publishable key) to run the app against.

## Install dependencies

```
cd app
flutter pub get
```

## Run analyze / tests

```
cd app
flutter analyze
flutter test
```

## Web build

```
cd app
flutter build web --dart-define=SUPABASE_URL=<your-project-url> --dart-define=SUPABASE_ANON_KEY=<your-anon-key>
```

`flutter run -d chrome --dart-define=...` works the same way for local
development with hot reload.

## Supabase configuration

The app reads its backend configuration **only** from `--dart-define` at
build/run time (`app/lib/config.dart`) -- never hardcoded in source:

```
--dart-define=SUPABASE_URL=<your-project-url>
--dart-define=SUPABASE_ANON_KEY=<your-project-anon-key>
```

Without these, the app shows an explicit "not configured" screen instead of
attempting a connection, so `flutter analyze`/`flutter test`/`flutter build`
always succeed with no extra flags.

**Security note**: only ever pass the project's public **anon/publishable**
key this way. The Supabase **service-role** key must never be placed in
Flutter/client code, `--dart-define` values, or anything shipped to a
device/browser -- it bypasses Row Level Security entirely and is meant only
for trusted server-side contexts (migrations, scheduled jobs), never the
client app.

## Database migrations and tests

These commands live in `test/scripts/` (repo root, one level up from `app/`)
and target a local PostgreSQL 17 instance on `localhost:5433`:

```
# From the repo root:
bash test/scripts/apply_migrations.sh   # applies supabase/migrations/ to the local test DB

cd test
npm install
npm test                                 # runs the DB security/regression suite (test/scripts/run_tests.mjs)
```

`apply_migrations.sh` expects a local PostgreSQL 17 server already running
on port 5433 with a `postgres`/`postgres` superuser login -- it creates
(drops and recreates) an `openplay_test` database for this purpose. It does
not touch any remote/production Supabase project.

## Releasing (Windows + Android)

One command, from the repo root:

```sh
npm run release              # patch bump: 1.0.1 -> 1.0.2
npm run release -- minor     # or: major
npm run release:preflight    # every check, nothing modified
```

It runs, in order, stopping at the first failure (nothing is published unless
everything before it passed): read-only preflight (branch `main`, allowed
changes only, versions in sync, gh write access to the public repo, tag free,
toolchain, `desktop/.env.local`, Android signing) → Flutter, desktop and
database tests → version bump (`desktop/package.json`, `desktop/package-lock.json`,
`app/pubspec.yaml`) → Windows installer build → Android release APK build →
artifact verification (installer, `latest.yml` sha512, packaged
`app-update.yml` and web build version, APK version/signature) → commit →
push → GitHub Release with `OpenPlay-Setup-X.exe`, its `.blockmap`,
`latest.yml` and `OpenPlay-Android-X.apk` → verification of the published
release.

- **Windows** installs update themselves from that GitHub Release
  (`desktop/electron/updater.cjs`): checked 12 s after launch and every 6 h,
  downloaded in the background, installed on "Restart now" or next close.
  Updater activity is logged to `%APPDATA%\OpenPlay\updater.log`.
- **Android** has no in-app updater: users install the APK from the release.

Prerequisites: `gh` logged in with write access to the repository in
`desktop/package.json` → `build.publish`, local Postgres test DB on :5433
running, `desktop/.env.local`, and `app/android/key.properties`.
