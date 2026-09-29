// electron-updater wiring for OpenPlay, mirroring Tournament Operator's
// proven pattern: auto-download, but never auto-install without the user
// confirming, gated by a busy check; every failure path degrades to "the
// app keeps running on its current version" rather than crashing.

const fs = require("fs");
const path = require("path");
const { app, dialog } = require("electron");
const {
  MIN_CHECK_INTERVAL_MS,
  PERIODIC_CHECK_MS,
  STARTUP_DELAY_MS,
  githubPublishConfig,
  isFeedConfigured,
  shouldCheckForUpdates,
  isUnsafeToAutoRestart,
} = require("./updatePolicy.cjs");

let autoUpdater = null;
try {
  ({ autoUpdater } = require("electron-updater"));
} catch (err) {
  // electron-updater not installed/resolvable -- degrade gracefully rather
  // than crash the app. attach() below no-ops in that case.
}

const state = {
  status: "idle", // idle | checking | available | downloading | ready | error | not-available | disabled
  version: null,
  progress: null,
  error: null,
};

let mainWindow = null;
let rendererContext = { busy: false, dialogOpen: false, pendingRequests: 0 };
let dismissedVersion = null;
let inProgress = false;
let nextCheckAllowed = 0;

// The packaged app has no visible console, so updater activity is also
// appended to <userData>/updater.log -- the only way to see from outside
// what an installed copy's updater actually did. Best-effort: logging must
// never break updating.
function log(level, ...args) {
  const line = args.map((a) => (a instanceof Error ? a.message : typeof a === "string" ? a : JSON.stringify(a))).join(" ");
  (level === "error" ? console.error : level === "warn" ? console.warn : console.log)("[updater]", line);
  try {
    fs.appendFileSync(
      path.join(app.getPath("userData"), "updater.log"),
      `${new Date().toISOString()} [${level}] v${app.getVersion()} ${line}
`
    );
  } catch {
    // ignore
  }
}

// OpenPlay's Flutter UI has no update banner, so a downloaded update is
// offered with a native dialog. "Later" keeps the existing behavior: the
// update installs silently the next time the app quits (autoInstallOnAppQuit).
async function promptRestart(version) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  try {
    const { response } = await dialog.showMessageBox(mainWindow, {
      type: "info",
      title: "OpenPlay update ready",
      message: `OpenPlay ${version} has been downloaded.`,
      detail: "Restart now to finish updating, or choose Later and it will be installed the next time you close OpenPlay.",
      buttons: ["Restart now", "Later"],
      defaultId: 0,
      cancelId: 1,
      noLink: true,
    });
    log("info", `restart prompt for ${version}: ${response === 0 ? "restart now" : "later"}`);
    if (response === 0 && !install()) log("warn", "restart deferred: renderer reported it is busy");
  } catch (err) {
    log("warn", "restart prompt failed:", err);
  }
}

function sendToMainWindow(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

function setState(patch) {
  Object.assign(state, patch);
  sendToMainWindow("updater:status", { ...state });
}

function attach(win) {
  mainWindow = win;

  if (!isFeedConfigured()) {
    // No verified release feed exists yet (see updatePolicy.cjs) -- never
    // poll a placeholder/nonexistent repository.
    setState({ status: "disabled" });
    log("warn", "disabled: no update feed configured");
    return;
  }

  if (!autoUpdater) {
    log("warn", "disabled: electron-updater is not available");
    return;
  }

  try {
    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = true;
    if ("autoInstallEvent" in autoUpdater) autoUpdater.autoInstallEvent = "onQuit";
    autoUpdater.allowDowngrade = false;
    autoUpdater.autoRunAppAfterInstall = true;
    // Only full NSIS installers are published; no web installer.
    if ("disableWebInstaller" in autoUpdater) autoUpdater.disableWebInstaller = true;
    autoUpdater.logger = {
      info: (...a) => log("info", ...a),
      warn: (...a) => log("warn", ...a),
      error: (...a) => log("error", ...a),
      debug: () => {},
    };
    autoUpdater.setFeedURL(githubPublishConfig());

    autoUpdater.on("checking-for-update", () => setState({ status: "checking" }));
    autoUpdater.on("update-available", (info) => setState({ status: "downloading", version: info?.version }));
    autoUpdater.on("update-not-available", () => setState({ status: "not-available" }));
    autoUpdater.on("download-progress", (progress) => setState({ progress }));
    autoUpdater.on("update-downloaded", (info) => {
      if (info?.version && info.version === dismissedVersion) {
        setState({ status: "idle" });
        return;
      }
      setState({ status: "ready", version: info?.version });
      promptRestart(info?.version);
    });
    autoUpdater.on("error", (err) => {
      // A late error after a good download shouldn't discard it.
      if (state.status === "ready") return;
      setState({ status: "error", error: String(err && err.message ? err.message : err) });
    });

    setTimeout(() => check(), STARTUP_DELAY_MS);
    const interval = setInterval(() => check(), PERIODIC_CHECK_MS);
    if (typeof interval.unref === "function") interval.unref();
  } catch (err) {
    log("warn", "disabled:", err && err.message ? err.message : String(err));
  }
}

async function check({ force = false } = {}) {
  if (!autoUpdater) return;
  if (!shouldCheckForUpdates({ packaged: app.isPackaged, disableUpdates: process.env.OPENPLAY_DISABLE_UPDATES === "1" })) {
    return;
  }
  if (inProgress) return;
  const now = Date.now();
  if (!force && now < nextCheckAllowed) return;

  inProgress = true;
  nextCheckAllowed = now + MIN_CHECK_INTERVAL_MS;
  try {
    await autoUpdater.checkForUpdates();
  } catch (err) {
    setState({ status: "error", error: String(err && err.message ? err.message : err) });
  } finally {
    inProgress = false;
  }
}

function install() {
  if (!autoUpdater || state.status !== "ready") return false;
  if (isUnsafeToAutoRestart(rendererContext)) {
    // Renderer still reports it's mid-operation; leave the "ready" banner
    // up rather than forcing a restart.
    return false;
  }
  // isSilent=true: OpenPlay ships an assisted (oneClick: false) NSIS
  // installer, so a non-silent update run shows the full setup wizard
  // ("Only for me / Next / Finish") -- observed in the real 1.0.1 -> 1.0.2
  // update test. Silent mode reuses the existing install location, and
  // forceRunAfter relaunches the app when the update is done.
  autoUpdater.quitAndInstall(true, true);
  return true;
}

function later() {
  if (state.version) dismissedVersion = state.version;
  setState({ status: "idle" });
}

function setContext(payload) {
  rendererContext = { ...rendererContext, ...(payload || {}) };
}

function getState() {
  return { ...state };
}

module.exports = { attach, check, install, later, setContext, getState };
