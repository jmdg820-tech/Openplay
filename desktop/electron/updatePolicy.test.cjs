// Tests for the updater policy (updatePolicy.cjs). Run: npm test

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  githubPublishConfig,
  isFeedConfigured,
  shouldCheckForUpdates,
  isUnsafeToAutoRestart,
} = require("./updatePolicy.cjs");

test("the shipped feed is the real OpenPlay GitHub repository", () => {
  assert.deepEqual(githubPublishConfig(), { provider: "github", owner: "jmdg820-tech", repo: "Openplay" });
  assert.equal(isFeedConfigured(), true);
});

test("the feed matches build.publish in desktop/package.json", () => {
  const publish = require("../package.json").build.publish;
  const entry = Array.isArray(publish) ? publish[0] : publish;
  assert.deepEqual(entry, githubPublishConfig());
});

test("updates never run while no feed is configured, even when packaged", () => {
  assert.equal(shouldCheckForUpdates({ packaged: true, disableUpdates: false, feedConfigured: false }), false);
});

test("the shipped feed is used only by packaged builds", () => {
  assert.equal(shouldCheckForUpdates({ packaged: true, disableUpdates: false }), true);
  assert.equal(shouldCheckForUpdates({ packaged: false, disableUpdates: false }), false);
});

test("placeholder or incomplete feeds are rejected as unconfigured", () => {
  assert.equal(isFeedConfigured({ provider: "github", owner: "REPLACE_WITH_GITHUB_OWNER", repo: "x" }), false);
  assert.equal(isFeedConfigured({ provider: "github", owner: "", repo: "openplay" }), false);
  assert.equal(isFeedConfigured({ provider: "s3", owner: "a", repo: "b" }), false);
});

test("with a real feed: only packaged, non-disabled builds check", () => {
  assert.equal(isFeedConfigured({ provider: "github", owner: "acme", repo: "openplay" }), true);
  assert.equal(shouldCheckForUpdates({ packaged: true, disableUpdates: false, feedConfigured: true }), true);
  assert.equal(shouldCheckForUpdates({ packaged: false, disableUpdates: false, feedConfigured: true }), false);
  assert.equal(shouldCheckForUpdates({ packaged: true, disableUpdates: true, feedConfigured: true }), false);
});

test("busy renderer context blocks auto-restart", () => {
  assert.equal(isUnsafeToAutoRestart({ busy: true }), true);
  assert.equal(isUnsafeToAutoRestart({ busy: false, dialogOpen: false, pendingRequests: 0 }), false);
});
