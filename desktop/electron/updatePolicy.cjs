// Pure policy/config logic for the OpenPlay auto-updater -- deliberately
// separated from updater.cjs (which wires this into electron-updater) so
// the decision rules can be reasoned about/tested independently.

const MIN_CHECK_INTERVAL_MS = 30 * 60 * 1000; // 30 minutes
const PERIODIC_CHECK_MS = 6 * 60 * 60 * 1000; // 6 hours
const STARTUP_DELAY_MS = 12 * 1000; // 12 seconds

// electron-updater feed: GitHub Releases on the public OpenPlay repository.
// `npm run release` (scripts/release.mjs) publishes OpenPlay-Setup-<v>.exe,
// its .blockmap and latest.yml there. Must stay identical to "build.publish"
// in desktop/package.json (release.mjs checks this) so the app-update.yml
// electron-builder packages agrees with the feed set explicitly below. The
// repository is public, so installed copies need no token to read it.
const UPDATE_FEED = Object.freeze({ provider: "github", owner: "jmdg820-tech", repo: "Openplay" });

function githubPublishConfig() {
  return { ...UPDATE_FEED }; // a copy: electron-updater may annotate the object it is given
}

function isFeedConfigured(feed = UPDATE_FEED) {
  return Boolean(
    feed &&
      feed.provider === "github" &&
      typeof feed.owner === "string" &&
      typeof feed.repo === "string" &&
      feed.owner.length > 0 &&
      feed.repo.length > 0 &&
      !/REPLACE_WITH/i.test(feed.owner + feed.repo)
  );
}

function shouldCheckForUpdates({ packaged, disableUpdates, feedConfigured = isFeedConfigured() }) {
  if (!feedConfigured) return false;
  if (!packaged) return false;
  if (disableUpdates) return false;
  return true;
}

// Mirrors Tournament's busy-guard shape: the renderer can report that an
// operation is in flight (e.g. a join/confirmation request) via the
// `updater:set-context` IPC channel; if so, a downloaded update is held in
// a "ready, but don't force it" state rather than auto-restarting under the
// user. Defaults to "not busy" if the renderer never reports a context,
// which is an honest default -- OpenPlay's Flutter UI does not yet call
// this, so today this always evaluates to safe.
function isUnsafeToAutoRestart(context) {
  if (!context) return false;
  return Boolean(context.busy || context.dialogOpen || context.pendingRequests > 0);
}

module.exports = {
  MIN_CHECK_INTERVAL_MS,
  PERIODIC_CHECK_MS,
  STARTUP_DELAY_MS,
  githubPublishConfig,
  isFeedConfigured,
  shouldCheckForUpdates,
  isUnsafeToAutoRestart,
};
