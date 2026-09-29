// Packages the OpenPlay Electron shell into a production Windows NSIS
// installer via electron-builder. Assumes desktop/webapp/ already contains
// a fresh Flutter web build (desktop's "build:desktop" npm script runs
// build-flutter-web.mjs first).

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DESKTOP_DIR = path.join(__dirname, "..", "desktop");

function main() {
  const args = ["electron-builder", "--win", "nsis", "--publish", "never"];
  console.log(`[build-desktop-win] running: npx ${args.join(" ")} (cwd=${DESKTOP_DIR})`);
  // shell:true is required: since Node's CVE-2024-27980 fix (18.20.2 /
  // 20.12.2 / 21.7.3+), spawning a .cmd/.bat without a shell fails with
  // EINVAL before the process even starts (status null). The arguments are
  // fixed constants above, so there is no user input to escape (passed as a
  // single command string -- Node deprecates args + shell:true, DEP0190).
  const result = spawnSync(`npx ${args.join(" ")}`, { cwd: DESKTOP_DIR, stdio: "inherit", shell: true });
  if (result.error) {
    throw new Error(`electron-builder could not be started: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`electron-builder failed with exit code ${result.status}`);
  }
  console.log("[build-desktop-win] done -- see desktop/release/");
}

main();
