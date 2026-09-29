// Builds the OpenPlay Flutter app for Web (the Electron shell's renderer)
// and copies the output into desktop/webapp/, which is what
// desktop/electron/main.cjs serves via the local static server and what
// electron-builder's "files" list packages into the installer.
//
// Reads SUPABASE_URL / SUPABASE_ANON_KEY from desktop/.env.local (gitignored,
// never committed) and passes them as --dart-define values -- the same
// build-time config-baking mechanism the app already uses for Android,
// just invoked here for the web target instead.

import { spawnSync } from "node:child_process";
import { readFileSync, existsSync, rmSync, cpSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.join(__dirname, "..");
const APP_DIR = path.join(REPO_ROOT, "app");
const ENV_FILE = path.join(REPO_ROOT, "desktop", ".env.local");
const WEBAPP_OUT = path.join(REPO_ROOT, "desktop", "webapp");

export function loadEnvFile(file = ENV_FILE) {
  if (!existsSync(file)) {
    throw new Error(
      `Missing ${file}. Create it with SUPABASE_URL and SUPABASE_ANON_KEY ` +
        `(see app/lib/config.dart for the expected values) before building the desktop app.`
    );
  }
  const env = {};
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const idx = trimmed.indexOf("=");
    if (idx === -1) continue;
    env[trimmed.slice(0, idx)] = trimmed.slice(idx + 1);
  }
  return env;
}

export function findFlutter() {
  // Prefer the same install this repo's other build steps have used.
  const candidates = [
    "C:\\Tools\\flutter\\bin\\flutter.bat",
    process.env.FLUTTER_ROOT ? path.join(process.env.FLUTTER_ROOT, "bin", "flutter.bat") : null,
    "flutter",
  ].filter(Boolean);
  for (const c of candidates) {
    if (c === "flutter" || existsSync(c)) return c;
  }
  return "flutter";
}

// The app shows this as "OpenPlay v<version>"; desktop/package.json is the
// Windows version source, kept equal to app/pubspec.yaml by release.mjs.
export function readDesktopVersion() {
  return JSON.parse(readFileSync(path.join(REPO_ROOT, "desktop", "package.json"), "utf8")).version;
}

function main() {
  const env = loadEnvFile(ENV_FILE);
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) {
    throw new Error(`${ENV_FILE} must define both SUPABASE_URL and SUPABASE_ANON_KEY.`);
  }

  const flutter = findFlutter();
  const args = [
    "build",
    "web",
    "--release",
    "--base-href",
    "/",
    `--dart-define=SUPABASE_URL=${env.SUPABASE_URL}`,
    `--dart-define=SUPABASE_ANON_KEY=${env.SUPABASE_ANON_KEY}`,
    `--dart-define=OPENPLAY_VERSION=${readDesktopVersion()}`,
  ];

  console.log(`[build-flutter-web] running: ${flutter} ${args.join(" ")}`);
  // flutter.bat is a Windows batch script -- spawnSync needs shell:true to
  // execute it directly (Node does not treat .bat as executable on its own).
  const result = spawnSync(flutter, args, { cwd: APP_DIR, stdio: "inherit", shell: true });
  if (result.status !== 0) {
    throw new Error(`flutter build web failed with exit code ${result.status}`);
  }

  const builtWeb = path.join(APP_DIR, "build", "web");
  if (!existsSync(builtWeb)) {
    throw new Error(`Expected Flutter web output at ${builtWeb}, but it does not exist.`);
  }

  rmSync(WEBAPP_OUT, { recursive: true, force: true });
  cpSync(builtWeb, WEBAPP_OUT, { recursive: true });
  console.log(`[build-flutter-web] copied ${builtWeb} -> ${WEBAPP_OUT}`);
}

// Run only when executed directly (release.mjs imports the helpers above).
// (Case-insensitive: Windows drive letters may differ in case.)
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]).toLowerCase() : "";
if (invokedPath === fileURLToPath(import.meta.url).toLowerCase()) main();
