// One-command production release for OpenPlay: Windows desktop (Electron +
// NSIS installer, auto-updated through GitHub Releases) and Android (signed
// release APK attached to the same GitHub Release -- Android has NO in-app
// updater; users install the APK manually).
//
//   npm run release                      patch bump (1.2.3 -> 1.2.4)
//   npm run release -- minor | major     minor / major bump
//   npm run release -- --preflight-only  run every read-only check, change nothing
//
// Order: PREFLIGHT (read-only) -> tests -> version bump -> Windows build ->
// Android build -> verify every artifact -> commit (allowlisted paths only) ->
// push -> GitHub Release (installer, blockmap, latest.yml, APK) -> verify the
// published release. Any failure stops the pipeline; fail() reports what was
// and was not modified and how to recover. Nothing is published unless tests,
// both builds and all artifact checks passed. Never force-pushes, never
// overwrites an existing tag or release, never switches the gh account.
//
// Version sources (kept identical by this script):
//   desktop/package.json + desktop/package-lock.json  "version"  (Windows)
//   app/pubspec.yaml  version: X.Y.Z+N  (Android versionName X.Y.Z, versionCode N)

import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { findFlutter, loadEnvFile } from "./build-flutter-web.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appDir = path.join(root, "app");
const androidDir = path.join(appDir, "android");
const desktopDir = path.join(root, "desktop");
const releaseDir = path.join(desktopDir, "release");
const require = createRequire(import.meta.url);
const lockPath = path.join(desktopDir, "node_modules", ".release.lock");
const commitMsgPath = path.join(desktopDir, "node_modules", ".release-commit-msg.txt");
const ANDROID_APP_ID = "com.openplay.openplay_app";

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------
const BUMP_TYPES = ["patch", "minor", "major"];
let preflightOnly = false;
const positional = [];
for (const arg of process.argv.slice(2)) {
  if (arg === "--preflight-only") preflightOnly = true;
  else if (arg.startsWith("--")) {
    console.error(`Unknown option "${arg}". Supported: --preflight-only.`);
    process.exit(1);
  } else positional.push(arg);
}
const bumpType = (positional[0] || "patch").toLowerCase();
if (positional.length > 1 || !BUMP_TYPES.includes(bumpType)) {
  console.error(`Usage: npm run release [-- patch|minor|major] [-- --preflight-only]`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// What a release may commit
// ---------------------------------------------------------------------------
const VERSION_FILES = ["desktop/package.json", "desktop/package-lock.json", "app/pubspec.yaml"];
const ALLOWED_ROOTS = ["app/", "desktop/", "scripts/", "supabase/", "docs/", "test/"];
const ALLOWED_ROOT_FILES = ["package.json", ".gitignore"];
const GENERATED_PREFIXES = [
  "app/build/", "app/.dart_tool/", "app/android/.gradle/", "app/android/app/build/",
  "desktop/release/", "desktop/webapp/", "desktop/dist/", "desktop/node_modules/", "test/node_modules/",
];
const GENERATED_FILE = /\.(apk|aab|exe|msi|blockmap|dll|class|dex|log)$/i;
const SECRET_PATTERNS = [
  /(^|\/)\.env(\.[^/]*)?$/i, /\.(jks|keystore|pem|p12|pfx)$/i,
  /(^|\/)key\.properties$/i, /(^|\/)local\.properties$/i, /credentials?/i, /secret/i,
];
const isSecret = (p) => !/\.example$/i.test(p) && SECRET_PATTERNS.some((re) => re.test(p));
const isReleasable = (p) =>
  (ALLOWED_ROOT_FILES.includes(p) || ALLOWED_ROOTS.some((r) => p.startsWith(r))) &&
  !GENERATED_PREFIXES.some((g) => p.startsWith(g)) && !GENERATED_FILE.test(p) && !isSecret(p);
const isReleasableEntry = (e) => isReleasable(e.path) && (!e.renamedFrom || isReleasable(e.renamedFrom));

// ---------------------------------------------------------------------------
// State + failure handling
// ---------------------------------------------------------------------------
const startedAt = Date.now();
let stage = "preflight";
const state = {
  baseSha: null, resume: false, versionsBumped: false, releaseDirCleaned: false,
  committed: false, commitHash: null, pushed: false, ghReleaseStarted: false, tag: null, slug: null,
};
const bumpedFiles = [];
let lockOwned = false;
let failing = false;

function logStep(name) {
  console.log(`\n--- ${name} ---`);
}

function releaseUnlock() {
  if (!lockOwned) return;
  try { unlinkSync(lockPath); } catch { /* already gone */ }
  lockOwned = false;
}

function acquireLock() {
  if (!existsSync(path.dirname(lockPath))) {
    console.error("desktop/node_modules is missing. Run `npm install` in desktop/ first.");
    process.exit(1);
  }
  if (existsSync(lockPath)) {
    const pid = Number.parseInt(readFileSync(lockPath, "utf8").trim(), 10);
    let alive = false;
    if (Number.isInteger(pid) && pid > 0) {
      try { process.kill(pid, 0); alive = true; } catch (err) { alive = err.code === "EPERM"; }
    }
    if (alive) {
      console.error(`Release already in progress (pid ${pid}, lock ${lockPath}).`);
      process.exit(1);
    }
    unlinkSync(lockPath);
  }
  writeFileSync(lockPath, String(process.pid), { flag: "wx" });
  lockOwned = true;
}

// Put bumped version files back, but only if they still hold exactly what the
// bump wrote. Only used while nothing has been committed.
function restoreVersionFiles() {
  return bumpedFiles.map((f) => {
    try {
      const current = readFileSync(f.path, "utf8");
      if (current === f.original) return `  ${f.rel}: unchanged`;
      if (current === f.written) {
        writeFileSync(f.path, f.original);
        return `  ${f.rel}: restored to its pre-release contents`;
      }
      return `  ${f.rel}: LEFT AS-IS (changed since the bump -- restore it manually)`;
    } catch (err) {
      return `  ${f.rel}: could not be restored (${err.message})`;
    }
  });
}

function describeState() {
  const lines = [];
  if (state.resume) lines.push(`Resume mode: version files untouched; releasing the already-committed HEAD (${state.baseSha?.slice(0, 7)}).`);
  else if (!state.versionsBumped) lines.push("Version files: NOT modified.");
  else if (!state.committed) lines.push("Version files were bumped and NOT committed. Automatic restore:", ...restoreVersionFiles());
  else lines.push(`Version files were bumped and committed (${state.commitHash}).`);
  lines.push(state.releaseDirCleaned ? "desktop/release/ was cleaned for this build; its contents may be partial." : "desktop/release/: untouched.");
  if (!state.resume) lines.push(state.committed ? `Commit: ${state.commitHash} exists locally.` : "Commit: none created.");
  lines.push(state.pushed ? "Push: origin/main was updated." : "Push: nothing pushed.");
  lines.push(state.ghReleaseStarted
    ? `GitHub release ${state.tag}: state UNCONFIRMED. Check: gh release view ${state.tag} --repo ${state.slug}`
    : "GitHub release: none created.");
  if (state.committed || state.resume) {
    // The version is committed but unpublished: a re-run detects that and
    // resumes (no second bump, no second commit).
    lines.push(
      `Recovery: fix the cause and re-run \`npm run release\` -- it resumes ${state.tag} from the committed version (no new bump or commit).` +
        (state.ghReleaseStarted ? ` If a partial release exists, delete it first: gh release delete ${state.tag} --repo ${state.slug} --cleanup-tag` : "")
    );
  } else {
    lines.push("Recovery: fix the reported problem and re-run `npm run release` (try `npm run release -- --preflight-only` first).");
  }
  return lines;
}

function fail(step, reason) {
  if (failing) process.exit(1);
  failing = true;
  const details = describeState();
  releaseUnlock();
  console.log(`
========================================
RELEASE FAILED
Stage:  ${stage}
Step:   ${step}
Reason: ${reason}

State:
${details.map((l) => (l.startsWith("  ") ? l : `- ${l}`)).join("\n")}

${state.ghReleaseStarted ? "GitHub release NOT confirmed -- verify manually." : "NO release was published."}
========================================`);
  process.exit(1);
}

process.on("exit", releaseUnlock);
process.on("SIGINT", () => fail("Interrupted", "Received SIGINT (Ctrl+C)."));
process.on("SIGTERM", () => fail("Interrupted", "Received SIGTERM."));
process.on("uncaughtException", (err) => fail("Unexpected error", err?.stack || String(err)));
process.on("unhandledRejection", (err) => fail("Unexpected error", err?.stack || String(err)));

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------
const q = (v) => (process.platform === "win32" && /\s/.test(v) && !/^".*"$/.test(v) ? `"${v}"` : v);

// Streams output. Commands are fixed strings built here (no user input);
// shell:true is required on Windows to run .bat/.cmd (npm, flutter).
function run(cmd, args, opts = {}) {
  const res = spawnSync([cmd, ...args].map(q).join(" "), { stdio: "inherit", shell: true, ...opts });
  if (res.error) throw res.error;
  return res.status ?? 1;
}
const capture = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...opts });
function tryCapture(cmd, args, opts = {}) {
  try {
    return { ok: true, output: capture(cmd, args, opts) };
  } catch (err) {
    return { ok: false, error: err, text: String(err.stderr || err.stdout || err.message || "").trim() };
  }
}
const git = (args) => capture("git", args, { cwd: root });
const sha = (algo, file, enc = "hex") => createHash(algo).update(readFileSync(file)).digest(enc);

function readWorkingTree() {
  const parts = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).split("\0").filter(Boolean);
  const entries = [];
  for (let i = 0; i < parts.length; i++) {
    const code = parts[i].slice(0, 2);
    const p = parts[i].slice(3);
    const renamedFrom = /[RC]/.test(code) ? parts[++i] ?? null : null;
    entries.push({ code, path: p, renamedFrom });
  }
  return entries;
}

function bumpVersion(v, type) {
  const [ma, mi, pa] = v.split(".").map((n) => Number.parseInt(n, 10));
  if (type === "major") return `${ma + 1}.0.0`;
  if (type === "minor") return `${ma}.${mi + 1}.0`;
  return `${ma}.${mi}.${pa + 1}`;
}

function compareVersions(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
  return 0;
}

function parseProperties(text) {
  const props = {};
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("=");
    if (i > 0) props[t.slice(0, i).trim()] = t.slice(i + 1).trim();
  }
  return props;
}

function findJavaHome() {
  const candidates = [process.env.JAVA_HOME, "C:\\Program Files\\Android\\Android Studio\\jbr"].filter(Boolean);
  return candidates.find((c) => existsSync(path.join(c, "bin", "java.exe"))) || null;
}

function findAndroidSdk() {
  const candidates = [process.env.ANDROID_HOME, process.env.ANDROID_SDK_ROOT];
  const lp = path.join(androidDir, "local.properties");
  if (existsSync(lp)) candidates.push(parseProperties(readFileSync(lp, "utf8"))["sdk.dir"]?.replace(/\\\\/g, "\\"));
  candidates.push(path.join(process.env.LOCALAPPDATA || "", "Android", "Sdk"));
  return candidates.find((c) => c && existsSync(c)) || null;
}

function findBuildTools(sdk) {
  const dir = path.join(sdk, "build-tools");
  if (!existsSync(dir)) return null;
  const versions = readdirSync(dir)
    .filter((v) => existsSync(path.join(dir, v, "aapt.exe")) && existsSync(path.join(dir, v, "apksigner.bat")))
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  return versions.length ? path.join(dir, versions.at(-1)) : null;
}

const parseGitHubSlug = (url) => {
  const m = String(url).match(/github\.com[/:]([^/]+)\/([^/]+?)(?:\.git)?\/?$/i);
  return m ? `${m[1]}/${m[2]}` : null;
};

// Throws if the tag/release exists anywhere, or if that cannot be determined.
function assertTagFree(tag, slug) {
  if (git(["tag", "--list", tag]).trim()) throw new Error(`Local git tag ${tag} already exists.`);
  const remote = tryCapture("git", ["ls-remote", "--tags", "origin", `refs/tags/${tag}`], { cwd: root });
  if (!remote.ok) throw new Error(`Could not query origin tags: ${remote.text}`);
  if (remote.output.trim()) throw new Error(`Tag ${tag} already exists on origin.`);
  const view = tryCapture("gh", ["release", "view", tag, "--repo", slug, "--json", "tagName"]);
  if (view.ok) throw new Error(`A GitHub release ${tag} already exists on ${slug}.`);
  if (!/release not found/i.test(view.text)) throw new Error(`Could not determine whether release ${tag} exists: ${view.text}`);
  return `${tag} is free locally, on origin and on ${slug}`;
}

// Minimal reader for electron-builder's latest.yml (flat keys + files list).
function readLatestYml(file) {
  const text = readFileSync(file, "utf8");
  const top = (k) => text.match(new RegExp(`^${k}:\\s*'?([^'\\r\\n]+)'?`, "m"))?.[1]?.trim();
  return { text, version: top("version"), path: top("path"), sha512: top("sha512") };
}

// ---------------------------------------------------------------------------
// 0. Lock
// ---------------------------------------------------------------------------
acquireLock();

// ---------------------------------------------------------------------------
// 1. PREFLIGHT -- read-only
// ---------------------------------------------------------------------------
const ctx = {};
function check(name, fn) {
  try {
    const detail = fn();
    console.log(`  PASS  ${name}${detail ? ` -- ${detail}` : ""}`);
  } catch (err) {
    fail(`Preflight: ${name}`, err.message);
  }
}

logStep("Preflight (read-only)");
const initialEntries = readWorkingTree();

check("Git branch is main, no operation in progress, nothing pre-staged", () => {
  const branch = git(["branch", "--show-current"]).trim();
  if (branch !== "main") throw new Error(`On branch "${branch || "(detached)"}"; releases are made from main.`);
  const busy = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"].filter((n) => existsSync(path.join(root, ".git", n)));
  if (busy.length) throw new Error(`Git operation in progress (${busy.join(", ")}).`);
  const staged = git(["diff", "--cached", "--name-only"]).trim();
  if (staged) throw new Error(`Index already has staged changes:\n${staged}\nUnstage them first (git restore --staged <path>).`);
  state.baseSha = git(["rev-parse", "HEAD"]).trim();
  return `HEAD ${state.baseSha.slice(0, 7)}`;
});

// The repo lives on a USB drive; an interrupted write once left empty object
// files behind a successful-looking commit. Refuse to build on a corrupt repo.
check("Repository integrity (git fsck --full)", () => {
  const fsck = tryCapture("git", ["fsck", "--full", "--no-dangling", "--no-progress"], { cwd: root });
  if (!fsck.ok) throw new Error(`git fsck reports corruption -- repair the repository before releasing:\n${fsck.text}`);
  return "no missing or corrupt objects";
});

check("Working tree holds only releasable source changes", () => {
  if (initialEntries.length === 0) return "clean (releasing already-committed changes)";
  for (const e of initialEntries) console.log(`           ${e.code} ${e.path}`);
  const secrets = initialEntries.filter((e) => isSecret(e.path));
  if (secrets.length) throw new Error(`Sensitive-looking path(s), refusing to commit:\n${secrets.map((e) => `  ${e.path}`).join("\n")}`);
  const versionDirty = initialEntries.filter((e) => VERSION_FILES.includes(e.path));
  if (versionDirty.length) throw new Error(`Version file(s) already modified (the release rewrites them):\n${versionDirty.map((e) => `  ${e.path}`).join("\n")}\nCommit or discard those edits first.`);
  const other = initialEntries.filter((e) => !isReleasableEntry(e));
  if (other.length) throw new Error(`Change(s) outside ${[...ALLOWED_ROOTS, ...ALLOWED_ROOT_FILES].join(", ")} or matching a generated-file pattern:\n${other.map((e) => `  ${e.code} ${e.path}`).join("\n")}\nCommit, stash or gitignore them first.`);
  return `${initialEntries.length} changed path(s) will be committed with the release`;
});

check("Windows and Android versions are in sync", () => {
  const desktopPkg = JSON.parse(readFileSync(path.join(desktopDir, "package.json"), "utf8"));
  const lock = JSON.parse(readFileSync(path.join(desktopDir, "package-lock.json"), "utf8"));
  const pubspec = readFileSync(path.join(appDir, "pubspec.yaml"), "utf8").match(/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m);
  if (!pubspec) throw new Error("app/pubspec.yaml has no `version: X.Y.Z+N` line.");
  ctx.current = desktopPkg.version;
  ctx.currentCode = Number.parseInt(pubspec[2], 10);
  if (!/^\d+\.\d+\.\d+$/.test(ctx.current)) throw new Error(`desktop/package.json version "${ctx.current}" is not X.Y.Z.`);
  if (pubspec[1] !== ctx.current) throw new Error(`Version mismatch: desktop/package.json ${ctx.current} vs app/pubspec.yaml ${pubspec[1]}.`);
  if (lock.version !== ctx.current || lock.packages?.[""]?.version !== ctx.current) throw new Error(`desktop/package-lock.json version does not match desktop/package.json (${ctx.current}).`);
  // A committed version newer than the last release tag means an earlier run
  // bumped + committed but never published: resume it instead of bumping again.
  const lastTag = tryCapture("git", ["describe", "--tags", "--abbrev=0", "--match", "v*"], { cwd: root });
  const lastVersion = lastTag.ok ? lastTag.output.trim().replace(/^v/, "") : null;
  if (lastVersion && /^\d+\.\d+\.\d+$/.test(lastVersion) && compareVersions(ctx.current, lastVersion) > 0) {
    if (initialEntries.length) throw new Error(`Resuming unpublished v${ctx.current} (committed, newer than v${lastVersion}) requires a clean working tree. Commit or stash the changes listed above first.`);
    if (bumpType !== "patch") throw new Error(`v${ctx.current} is committed but unpublished; resume it with a plain \`npm run release\` before requesting a ${bumpType} bump.`);
    state.resume = true;
    ctx.next = ctx.current;
    ctx.nextCode = ctx.currentCode;
    state.tag = `v${ctx.next}`;
    return `RESUME: ${ctx.current}+${ctx.currentCode} is already committed (HEAD ${state.baseSha.slice(0, 7)}) but unpublished (last release v${lastVersion}) -- no bump, no new commit`;
  }
  ctx.next = bumpVersion(ctx.current, bumpType);
  ctx.nextCode = ctx.currentCode + 1;
  state.tag = `v${ctx.next}`;
  return `${ctx.current}+${ctx.currentCode} -> ${ctx.next}+${ctx.nextCode}`;
});

check("There is something to release", () => {
  if (state.resume) return `unpublished v${ctx.next} is committed`;
  if (initialEntries.length) return "working tree has changes";
  const prevTag = tryCapture("git", ["describe", "--tags", "--abbrev=0", "--match", "v*"], { cwd: root });
  if (prevTag.ok) {
    const tag = prevTag.output.trim();
    const count = git(["rev-list", "--count", `${tag}..HEAD`]).trim();
    if (count === "0") throw new Error(`Nothing to release: working tree is clean and HEAD is already released as ${tag}.`);
    return `${count} commit(s) since ${tag}`;
  }
  return "no previous release tag";
});

check("Update feed matches electron-builder publish config and origin", () => {
  const { githubPublishConfig, isFeedConfigured } = require(path.join(desktopDir, "electron", "updatePolicy.cjs"));
  const feed = githubPublishConfig();
  if (!isFeedConfigured(feed)) throw new Error("desktop/electron/updatePolicy.cjs has no configured GitHub feed -- installed apps could never update.");
  const publish = JSON.parse(readFileSync(path.join(desktopDir, "package.json"), "utf8")).build?.publish;
  const pub = Array.isArray(publish) ? publish[0] : publish;
  if (!pub || pub.provider !== "github" || pub.owner !== feed.owner || pub.repo !== feed.repo) {
    throw new Error(`desktop/package.json build.publish (${JSON.stringify(pub)}) must equal the updater feed ${feed.owner}/${feed.repo}.`);
  }
  const origin = tryCapture("git", ["remote", "get-url", "origin"], { cwd: root });
  if (!origin.ok) throw new Error("No `origin` remote configured.");
  const slug = parseGitHubSlug(origin.output.trim());
  if (!slug || slug.toLowerCase() !== `${feed.owner}/${feed.repo}`.toLowerCase()) {
    throw new Error(`origin (${origin.output.trim()}) is not the update feed repository ${feed.owner}/${feed.repo}.`);
  }
  ctx.slug = state.slug = `${feed.owner}/${feed.repo}`;
  return ctx.slug;
});

check("GitHub CLI is authenticated with write access", () => {
  const login = tryCapture("gh", ["api", "user", "--jq", ".login"]);
  if (!login.ok) throw new Error(`gh is not authenticated (${login.text}). Run: gh auth login`);
  const info = tryCapture("gh", ["repo", "view", ctx.slug, "--json", "viewerPermission,visibility", "--jq", '.viewerPermission + " " + .visibility']);
  if (!info.ok) throw new Error(`Could not read ${ctx.slug}: ${info.text}`);
  const [perm, visibility] = info.output.trim().split(" ");
  if (!["ADMIN", "MAINTAIN", "WRITE"].includes(perm)) {
    throw new Error(`Active gh account "${login.output.trim()}" has ${perm} on ${ctx.slug}; WRITE is required. Log in as an account with write access (gh auth login / gh auth switch).`);
  }
  if (visibility !== "PUBLIC") throw new Error(`${ctx.slug} is ${visibility}; installed apps cannot read private releases without a token.`);
  return `${login.output.trim()} (${perm}), repo is public`;
});

check("origin/main is contained in HEAD", () => {
  const remote = tryCapture("git", ["ls-remote", "origin", "refs/heads/main"], { cwd: root });
  if (!remote.ok) throw new Error(`Could not query origin: ${remote.text}`);
  const remoteSha = remote.output.trim().split(/\s+/)[0];
  if (!remoteSha) throw new Error("origin has no main branch yet. Push main first: git push -u origin main");
  if (remoteSha === state.baseSha) return "origin/main == HEAD";
  const anc = tryCapture("git", ["merge-base", "--is-ancestor", remoteSha, "HEAD"], { cwd: root });
  if (!anc.ok) throw new Error(`origin/main (${remoteSha.slice(0, 7)}) is not an ancestor of HEAD -- run git pull and reconcile first.`);
  return `origin/main ${remoteSha.slice(0, 7)} is an ancestor of HEAD`;
});

check("Release tag is free", () => assertTagFree(state.tag, ctx.slug));

check("Build tooling is available", () => {
  ctx.flutter = findFlutter();
  const fv = tryCapture("cmd.exe", ["/d", "/c", `${q(ctx.flutter)} --version`]);
  if (!fv.ok) throw new Error(`Flutter not runnable (${ctx.flutter}).`);
  for (const p of ["electron-builder", "electron", "electron-updater", "@electron/asar"]) {
    if (!existsSync(path.join(desktopDir, "node_modules", p, "package.json"))) throw new Error(`desktop/node_modules/${p} missing -- run npm install in desktop/.`);
  }
  if (!existsSync(path.join(root, "test", "node_modules", "pg", "package.json"))) throw new Error("test/node_modules missing -- run npm install in test/.");
  ctx.javaHome = findJavaHome();
  if (!ctx.javaHome) throw new Error("No JDK found. Set JAVA_HOME or install Android Studio (its JBR is auto-detected).");
  ctx.androidSdk = findAndroidSdk();
  if (!ctx.androidSdk) throw new Error("No Android SDK found. Set ANDROID_HOME or fix app/android/local.properties.");
  ctx.buildTools = findBuildTools(ctx.androidSdk);
  if (!ctx.buildTools) throw new Error(`No build-tools with aapt.exe + apksigner.bat under ${ctx.androidSdk}.`);
  return `${fv.output.split(/\r?\n/)[0]}; JDK ${ctx.javaHome}; build-tools ${path.basename(ctx.buildTools)}`;
});

check("Production config (desktop/.env.local) is present", () => {
  ctx.env = loadEnvFile();
  if (!ctx.env.SUPABASE_URL || !ctx.env.SUPABASE_ANON_KEY) throw new Error("desktop/.env.local must define SUPABASE_URL and SUPABASE_ANON_KEY.");
  return `SUPABASE_URL=${ctx.env.SUPABASE_URL} (key not printed)`;
});

check("Android release signing is configured", () => {
  const kp = path.join(androidDir, "key.properties");
  if (!existsSync(kp)) throw new Error("app/android/key.properties is missing -- a release APK cannot be signed (see key.properties.example).");
  const props = parseProperties(readFileSync(kp, "utf8"));
  const missing = ["storeFile", "storePassword", "keyAlias", "keyPassword"].filter((k) => !props[k] || /REPLACE_WITH/.test(props[k]));
  if (missing.length) throw new Error(`key.properties has missing/placeholder value(s) for: ${missing.join(", ")}.`);
  if (!existsSync(path.resolve(androidDir, "app", props.storeFile))) throw new Error(`Keystore not found (${props.storeFile}, resolved from app/android/app/).`);
  return "key.properties complete, keystore exists (values not printed)";
});

logStep("Preflight: tests");
const testSuites = [
  ["Flutter app tests (excluding the manual visual-qa harness)", ctx.flutter, ["test", "--exclude-tags", "visual-qa"], appDir],
  ["Desktop (Electron) tests", "npm", ["test"], desktopDir],
  ["Database tests (local Postgres :5433)", "npm", ["test"], path.join(root, "test")],
];
for (const [name, cmd, args, cwd] of testSuites) {
  console.log(`\n> ${name}`);
  if (run(cmd, args, { cwd }) !== 0) fail(`Preflight: ${name}`, `${name} failed -- see output above. Nothing was modified.`);
  console.log(`  PASS  ${name}`);
}

console.log(`
Preflight PASSED.
  Version: ${state.resume ? `${ctx.next}+${ctx.nextCode} (resume: already committed, no bump)` : `${ctx.current}+${ctx.currentCode} -> ${ctx.next}+${ctx.nextCode}`}
  Release: ${state.tag} on ${ctx.slug}`);
if (preflightOnly) {
  releaseUnlock();
  console.log("\n--preflight-only: stopping. Nothing was modified.");
  process.exit(0);
}

// ---------------------------------------------------------------------------
// 2. Version bump (first modification)
// ---------------------------------------------------------------------------
stage = "version-bump";
logStep("Apply version bump");
if (state.resume) {
  console.log(`Resume: ${ctx.next}+${ctx.nextCode} is already committed -- skipping the bump.`);
} else {
  state.versionsBumped = true;
  const bumpPlan = [
    ["desktop/package.json", (raw) => raw.replace(/("version":\s*)"[^"]+"/, `$1"${ctx.next}"`)],
    // Top-level "version" and packages[""].version -- the first two occurrences.
    ["desktop/package-lock.json", (raw) => {
      let n = 0;
      return raw.replace(/("version":\s*)"[^"]+"/g, (m, k) => (n++ < 2 ? `${k}"${ctx.next}"` : m));
    }],
    ["app/pubspec.yaml", (raw) => raw.replace(/^version:\s*\S+/m, `version: ${ctx.next}+${ctx.nextCode}`)],
  ];
  for (const [rel, edit] of bumpPlan) {
    const p = path.join(root, rel);
    const original = readFileSync(p, "utf8");
    bumpedFiles.push({ rel, path: p, original, written: edit(original) });
  }
  for (const f of bumpedFiles) writeFileSync(f.path, f.written);
  {
    const lock = JSON.parse(readFileSync(path.join(desktopDir, "package-lock.json"), "utf8"));
    if (lock.version !== ctx.next || lock.packages[""].version !== ctx.next) fail("Version bump", "package-lock.json bump did not land on the expected fields.");
  }
  console.log(`${ctx.current}+${ctx.currentCode} -> ${ctx.next}+${ctx.nextCode}`);
}

// ---------------------------------------------------------------------------
// 3. Builds (always from current source; stale output is deleted first)
// ---------------------------------------------------------------------------
const buildStartMs = Date.now() - 5000;
const exeName = `OpenPlay-Setup-${ctx.next}.exe`;
const apkName = `OpenPlay-Android-${ctx.next}.apk`;
const exePath = path.join(releaseDir, exeName);
const blockmapPath = `${exePath}.blockmap`;
const latestYmlPath = path.join(releaseDir, "latest.yml");
const apkPath = path.join(releaseDir, apkName);
const flutterApk = path.join(appDir, "build", "app", "outputs", "flutter-apk", "app-release.apk");

stage = "windows-build";
logStep("Build Windows (Flutter web + electron-builder NSIS)");
state.releaseDirCleaned = true;
rmSync(releaseDir, { recursive: true, force: true });
if (run("npm", ["run", "build:desktop"], { cwd: desktopDir }) !== 0) fail("Windows build", "`npm run build:desktop` failed -- see output above.");

stage = "android-build";
logStep("Build Android (flutter build apk --release)");
rmSync(flutterApk, { force: true });
const apkStatus = run(ctx.flutter, [
  "build", "apk", "--release",
  `--dart-define=SUPABASE_URL=${ctx.env.SUPABASE_URL}`,
  `--dart-define=SUPABASE_ANON_KEY=${ctx.env.SUPABASE_ANON_KEY}`,
  `--dart-define=OPENPLAY_VERSION=${ctx.next}`,
], { cwd: appDir, env: { ...process.env, JAVA_HOME: ctx.javaHome, ANDROID_HOME: ctx.androidSdk } });
if (apkStatus !== 0) fail("Android build", "`flutter build apk --release` failed -- see output above.");
if (!existsSync(flutterApk)) fail("Android build", `Expected ${flutterApk} after the build, but it does not exist.`);
mkdirSync(releaseDir, { recursive: true });
copyFileSync(flutterApk, apkPath);

// ---------------------------------------------------------------------------
// 4. Verify artifacts (exit codes alone are not proof)
// ---------------------------------------------------------------------------
stage = "verify";
function freshFile(p, label) {
  if (!existsSync(p)) fail(`Verify ${label}`, `Missing ${p}`);
  const st = statSync(p);
  if (st.mtimeMs < buildStartMs) fail(`Verify ${label}`, `${p} predates this build run -- refusing a stale artifact.`);
  return st;
}

logStep("Verify Windows artifacts");
const exeStat = freshFile(exePath, "installer");
freshFile(blockmapPath, "blockmap");
freshFile(latestYmlPath, "latest.yml");
{
  const head = readFileSync(exePath).subarray(0, 2_000_000);
  if (head[0] !== 0x4d || head[1] !== 0x5a || !head.toString("latin1").includes("Nullsoft")) fail("Verify installer", `${exeName} is not an NSIS installer.`);
  const latest = readLatestYml(latestYmlPath);
  if (latest.version !== ctx.next) fail("Verify latest.yml", `latest.yml version is ${latest.version}, expected ${ctx.next}.`);
  if (latest.path !== exeName) fail("Verify latest.yml", `latest.yml path is ${latest.path}, expected ${exeName}.`);
  const exeSha512 = sha("sha512", exePath, "base64");
  if (latest.sha512 !== exeSha512) fail("Verify latest.yml", "latest.yml sha512 does not match the installer.");
  const pv = tryCapture("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", `(Get-Item -LiteralPath '${exePath}').VersionInfo.ProductVersion`]);
  const productVersion = pv.ok ? pv.output.trim() : null;
  if (productVersion && productVersion !== ctx.next) fail("Verify installer", `Installer ProductVersion ${productVersion}, expected ${ctx.next}.`);
  const resDir = path.join(releaseDir, "win-unpacked", "resources");
  const appUpdateYml = readFileSync(path.join(resDir, "app-update.yml"), "utf8");
  const feedOwner = ctx.slug.split("/")[0];
  const feedRepo = ctx.slug.split("/")[1];
  if (!/provider:\s*github/.test(appUpdateYml) || !appUpdateYml.includes(`owner: ${feedOwner}`) || !appUpdateYml.includes(`repo: ${feedRepo}`)) {
    fail("Verify installer", `Packaged app-update.yml does not point at ${ctx.slug}:\n${appUpdateYml}`);
  }
  // The renderer inside the package must be the web build made just now.
  const asar = require(path.join(desktopDir, "node_modules", "@electron", "asar"));
  const asarPath = path.join(resDir, "app.asar");
  const webVersion = JSON.parse(asar.extractFile(asarPath, "webapp/version.json").toString("utf8"));
  if (webVersion.version !== ctx.next || String(webVersion.build_number) !== String(ctx.nextCode)) {
    fail("Verify installer", `Packaged webapp/version.json is ${webVersion.version}+${webVersion.build_number}, expected ${ctx.next}+${ctx.nextCode} (stale web build).`);
  }
  const pkgVersion = JSON.parse(asar.extractFile(asarPath, "package.json").toString("utf8")).version;
  if (pkgVersion !== ctx.next) fail("Verify installer", `Packaged package.json version ${pkgVersion}, expected ${ctx.next}.`);
  console.log(`Installer:      ${exeName} (${exeStat.size} bytes, ${exeStat.mtime.toISOString()}), ProductVersion ${productVersion ?? "n/a"}`);
  console.log(`latest.yml:     version ${latest.version}, path ${latest.path}, sha512 matches installer`);
  console.log(`app-update.yml: github ${ctx.slug}`);
  console.log(`Packaged app:   package.json ${pkgVersion}, webapp ${webVersion.version}+${webVersion.build_number}`);
}

logStep("Verify Android APK");
const apkStat = freshFile(apkPath, "APK");
{
  const badging = tryCapture(path.join(ctx.buildTools, "aapt.exe"), ["dump", "badging", apkPath]);
  if (!badging.ok) fail("Verify APK", `aapt dump badging failed: ${badging.text}`);
  const pkgLine = badging.output.split(/\r?\n/).find((l) => l.startsWith("package:")) || "";
  const appId = pkgLine.match(/name='([^']+)'/)?.[1];
  const vCode = pkgLine.match(/versionCode='([^']+)'/)?.[1];
  const vName = pkgLine.match(/versionName='([^']+)'/)?.[1];
  if (appId !== ANDROID_APP_ID) fail("Verify APK", `applicationId ${appId}, expected ${ANDROID_APP_ID}.`);
  if (vName !== ctx.next || vCode !== String(ctx.nextCode)) fail("Verify APK", `APK is ${vName} (${vCode}), expected ${ctx.next} (${ctx.nextCode}).`);
  if (/^application-debuggable/m.test(badging.output)) fail("Verify APK", "APK is debuggable -- not a release build.");
  const sig = tryCapture("cmd.exe", ["/d", "/c", `${q(path.join(ctx.buildTools, "apksigner.bat"))} verify --print-certs ${q(apkPath)}`], {
    env: { ...process.env, JAVA_HOME: ctx.javaHome },
  });
  if (!sig.ok) fail("Verify APK", `apksigner verify failed: ${sig.text}`);
  ctx.signerDn = sig.output.match(/certificate DN:\s*(.+)/)?.[1]?.trim();
  ctx.signerSha256 = sig.output.match(/certificate SHA-256 digest:\s*([0-9a-f]+)/i)?.[1];
  if (!ctx.signerDn || /Android Debug/i.test(ctx.signerDn)) fail("Verify APK", `Unexpected signer: ${ctx.signerDn || "(none)"}.`);
  console.log(`APK:     ${apkName} (${apkStat.size} bytes, ${apkStat.mtime.toISOString()})`);
  console.log(`Package: ${appId} versionName ${vName} versionCode ${vCode} (release, not debuggable)`);
  console.log(`Signer:  ${ctx.signerDn} SHA-256 ${ctx.signerSha256}`);
}

// ---------------------------------------------------------------------------
// 5. Commit -- only the paths preflight approved, plus the version files
// ---------------------------------------------------------------------------
stage = "commit";
logStep("Commit");
if (git(["rev-parse", "HEAD"]).trim() !== state.baseSha) fail("Commit", "HEAD moved since preflight.");
const postEntries = readWorkingTree();
let commitSha;
if (state.resume) {
  // Nothing to commit: the release commit already exists. The build must not
  // have changed any tracked or untracked source either.
  if (postEntries.length) fail("Commit", `Resume mode expects a clean tree, but the build changed:\n${postEntries.map((e) => `  ${e.code} ${e.path}`).join("\n")}`);
  commitSha = state.baseSha;
  state.commitHash = commitSha.slice(0, 7);
  console.log(`Resume: releasing existing commit ${state.commitHash} (no new commit)`);
} else {
  const strays = postEntries.filter((e) => !VERSION_FILES.includes(e.path) && !isReleasableEntry(e));
  if (strays.length) fail("Commit", `Unexpected change(s) appeared during the build:\n${strays.map((e) => `  ${e.code} ${e.path}`).join("\n")}`);
  const missingBump = VERSION_FILES.filter((p) => !postEntries.some((e) => e.path === p));
  if (missingBump.length) fail("Commit", `Version file(s) not modified: ${missingBump.join(", ")}`);
  const toStage = postEntries.flatMap((e) => (e.renamedFrom ? [e.path, e.renamedFrom] : [e.path]));
  if (git(["diff", "--cached", "--name-only"]).trim()) fail("Commit", "The index gained staged changes during the release.");
  try {
    capture("git", ["add", "-A", "--", ...toStage], { cwd: root });
  } catch (err) {
    fail("Commit", `git add failed: ${err.message}`);
  }
  const staged = git(["diff", "--cached", "--name-only", "-z"]).split("\0").filter(Boolean).sort();
  const expected = [...new Set(postEntries.map((e) => e.path))].sort();
  if (staged.join("\n") !== expected.join("\n")) {
    try { capture("git", ["restore", "--staged", "--", ...toStage], { cwd: root }); } catch { /* best effort */ }
    fail("Commit", `Staged set differs from the approved set.\n  expected: ${expected.join(", ")}\n  staged:   ${staged.join(", ")}`);
  }
  const stagedTree = git(["write-tree"]).trim();
  writeFileSync(commitMsgPath, `Release v${ctx.next}\n\n- Windows desktop: ${ctx.current} -> ${ctx.next}\n- Android: ${ctx.current} (${ctx.currentCode}) -> ${ctx.next} (${ctx.nextCode})\n`);
  try {
    capture("git", ["commit", "-F", commitMsgPath], { cwd: root });
  } catch (err) {
    // git can exit non-zero AFTER updating HEAD (e.g. printing the summary
    // failed). If HEAD is exactly our commit, it succeeded -- never report
    // "commit failed" and never restore version files over a real commit.
    const head = tryCapture("git", ["rev-parse", "HEAD", "HEAD^", "HEAD^{tree}"], { cwd: root });
    const [headSha, parentSha, headTree] = head.ok ? head.output.trim().split(/\r?\n/) : [];
    if (headSha && headSha !== state.baseSha && parentSha === state.baseSha && headTree === stagedTree) {
      console.log(`WARNING: git commit exited non-zero but created the release commit ${headSha.slice(0, 7)}:\n${String(err.stderr || err.message).trim()}`);
    } else {
      try { capture("git", ["restore", "--staged", "--", ...toStage], { cwd: root }); } catch { /* best effort */ }
      fail("Commit", `git commit failed: ${String(err.stderr || err.message)}`);
    }
  } finally {
    try { unlinkSync(commitMsgPath); } catch { /* ignore */ }
  }
  state.committed = true;
  commitSha = git(["rev-parse", "HEAD"]).trim();
  state.commitHash = commitSha.slice(0, 7);
  // Every blob of the new commit must be readable (the diff reads them all);
  // a corrupt commit must never reach push.
  const integrity = tryCapture("git", ["diff", "--stat", state.baseSha, commitSha], { cwd: root });
  const matches = tryCapture("git", ["diff", "--quiet", commitSha, "--", ...toStage], { cwd: root });
  if (!integrity.ok || !matches.ok) {
    fail("Commit", `Commit ${state.commitHash} was created but cannot be read back intact (run \`git fsck --full\`):\n${integrity.text || matches.text || "working tree differs from the commit"}`);
  }
  console.log(`Committed ${state.commitHash} (${staged.length} path(s)), contents verified`);
}

// ---------------------------------------------------------------------------
// 6. Push -- plain push, never forced, then verified
// ---------------------------------------------------------------------------
stage = "push";
logStep("Push");
if (run("git", ["push", "origin", "main"], { cwd: root }) !== 0) fail("Push", "`git push origin main` failed -- see output above. Never force-push.");
{
  const remote = tryCapture("git", ["ls-remote", "origin", "refs/heads/main"], { cwd: root });
  const remoteSha = remote.ok ? remote.output.trim().split(/\s+/)[0] : "";
  if (remoteSha !== commitSha) fail("Push", `origin/main is ${remoteSha.slice(0, 7) || "unreadable"}, expected ${state.commitHash}.`);
  state.pushed = true;
  console.log(`origin/main == ${state.commitHash} (verified)`);
}

// ---------------------------------------------------------------------------
// 7. GitHub Release -- Windows update files + Android APK in one release
// ---------------------------------------------------------------------------
stage = "github-release";
logStep("Create GitHub Release");
try {
  assertTagFree(state.tag, ctx.slug);
} catch (err) {
  fail("GitHub Release", err.message);
}
const prevTag = tryCapture("git", ["describe", "--tags", "--abbrev=0", "--match", "v*", `${commitSha}^`], { cwd: root });
const changes = git(["log", "--no-merges", "--format=- %s (%h)", prevTag.ok ? `${prevTag.output.trim()}..${commitSha}` : "-20", ...(prevTag.ok ? [] : [commitSha])]).trim();
const notes = `OpenPlay ${ctx.next}

**Windows:** installed copies update automatically (download in the background, then restart when prompted or on next close). New installs: run \`${exeName}\`.
**Android:** download \`${apkName}\` and install it (Android does not auto-update). versionCode ${ctx.nextCode}.

Changes${prevTag.ok ? ` since ${prevTag.output.trim()}` : ""}:
${changes}
`;
const notesPath = path.join(desktopDir, "node_modules", ".release-notes.md");
writeFileSync(notesPath, notes);
state.ghReleaseStarted = true;
const createStatus = run("gh", [
  "release", "create", state.tag, "--repo", ctx.slug, "--target", commitSha,
  "--title", state.tag, "--notes-file", notesPath, "--latest",
  exePath, blockmapPath, latestYmlPath, apkPath,
], { cwd: root });
try { unlinkSync(notesPath); } catch { /* ignore */ }
if (createStatus !== 0) fail("GitHub Release", "`gh release create` failed -- see output above.");

// ---------------------------------------------------------------------------
// 8. Verify the published release independently
// ---------------------------------------------------------------------------
stage = "verify-release";
logStep("Verify published release");
const view = tryCapture("gh", ["release", "view", state.tag, "--repo", ctx.slug, "--json", "tagName,isDraft,isPrerelease,url,assets"]);
if (!view.ok) fail("Verify release", `gh could not read ${state.tag}: ${view.text}`);
const published = JSON.parse(view.output);
if (published.isDraft || published.isPrerelease) fail("Verify release", `${state.tag} is a draft/prerelease -- electron-updater would ignore it.`);
for (const file of [exePath, blockmapPath, latestYmlPath, apkPath]) {
  const name = path.basename(file);
  const asset = published.assets.find((a) => a.name === name);
  if (!asset) fail("Verify release", `Missing asset ${name}.`);
  const size = statSync(file).size;
  if (asset.size !== size) fail("Verify release", `${name}: remote ${asset.size} bytes, local ${size}.`);
  if (asset.digest?.startsWith("sha256:")) {
    if (asset.digest.slice(7) !== sha("sha256", file)) fail("Verify release", `${name}: sha256 differs from the local file.`);
    console.log(`  ${name}: ${size} bytes, sha256 matches`);
  } else {
    console.log(`  ${name}: ${size} bytes (no digest from GitHub; size matches)`);
  }
}
const latestApi = tryCapture("gh", ["api", `repos/${ctx.slug}/releases/latest`, "--jq", ".tag_name"]);
if (!latestApi.ok || latestApi.output.trim() !== state.tag) fail("Verify release", `GitHub's "latest release" is ${latestApi.ok ? latestApi.output.trim() : "unreadable"}, not ${state.tag}.`);
const tagSha = tryCapture("git", ["ls-remote", "origin", `refs/tags/${state.tag}`], { cwd: root });
if (!tagSha.ok || tagSha.output.trim().split(/\s+/)[0] !== commitSha) fail("Verify release", `Tag ${state.tag} on origin does not point at ${state.commitHash}.`);
tryCapture("git", ["fetch", "origin", "tag", state.tag, "--no-tags"], { cwd: root });
console.log(`Release ${state.tag} verified: latest release, tag -> ${state.commitHash}, ${published.url}`);

// ---------------------------------------------------------------------------
// Done
// ---------------------------------------------------------------------------
const treeAfter = readWorkingTree();
releaseUnlock();
console.log(`
========================================
RELEASE COMPLETE  ${state.tag}  (${Math.round((Date.now() - startedAt) / 1000)}s)

Windows:  ${exeName} + blockmap + latest.yml -> installed apps auto-update
Android:  ${apkName} (versionCode ${ctx.nextCode}, signer ${ctx.signerSha256?.slice(0, 16)}...) -- manual install, no auto-update
Tests:    Flutter, Desktop, Database: PASS
Git:      ${state.commitHash} pushed to origin/main; tag ${state.tag}
Tree:     ${treeAfter.length === 0 ? "clean" : `${treeAfter.length} path(s) still changed`}
Release:  ${published.url}
========================================`);
