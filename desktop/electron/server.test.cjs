// Regression tests for the stable-origin fix (server.cjs). Run: npm test
// Uses only Node built-ins (node:test), so no Electron runtime is needed.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const { startStaticServer, resolvePort, DEFAULT_PORT } = require("./server.cjs");

function makeWebRoot() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "openplay-webroot-"));
  fs.writeFileSync(path.join(dir, "index.html"), "<!doctype html><title>OpenPlay</title>");
  return dir;
}

function get(port, urlPath) {
  return new Promise((resolve, reject) => {
    http
      .get({ host: "127.0.0.1", port, path: urlPath }, (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => resolve({ status: res.statusCode, body }));
      })
      .on("error", reject);
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

// A free high port for tests, so they never collide with a running app.
function freePort() {
  return new Promise((resolve) => {
    const s = http.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

test("default port is fixed (never 0/ephemeral)", () => {
  assert.equal(typeof DEFAULT_PORT, "number");
  assert.ok(DEFAULT_PORT >= 1024);
  assert.equal(resolvePort({}), DEFAULT_PORT);
});

test("OPENPLAY_DESKTOP_PORT override is honoured; invalid values fall back to the fixed default", () => {
  assert.equal(resolvePort({ OPENPLAY_DESKTOP_PORT: "50123" }), 50123);
  assert.equal(resolvePort({ OPENPLAY_DESKTOP_PORT: "0" }), DEFAULT_PORT);
  assert.equal(resolvePort({ OPENPLAY_DESKTOP_PORT: "80" }), DEFAULT_PORT);
  assert.equal(resolvePort({ OPENPLAY_DESKTOP_PORT: "abc" }), DEFAULT_PORT);
});

test("binds to exactly the requested port on loopback and serves index.html", async () => {
  const root = makeWebRoot();
  const port = await freePort();
  const { server, port: bound } = await startStaticServer(root, { port });
  try {
    assert.equal(bound, port);
    assert.equal(server.address().address, "127.0.0.1");
    const res = await get(port, "/");
    assert.equal(res.status, 200);
    assert.match(res.body, /OpenPlay/);
  } finally {
    await close(server);
  }
});

test("origin is identical across two sequential launches (the sign-in persistence fix)", async () => {
  const root = makeWebRoot();
  const port = await freePort();
  const first = await startStaticServer(root, { port });
  const origin1 = `http://127.0.0.1:${first.port}`;
  await close(first.server);
  const second = await startStaticServer(root, { port });
  const origin2 = `http://127.0.0.1:${second.port}`;
  await close(second.server);
  assert.equal(origin1, origin2);
});

test("occupied port -> clear OPENPLAY_PORT_IN_USE error, never a silent fallback port", async () => {
  const root = makeWebRoot();
  const port = await freePort();
  const blocker = http.createServer();
  await new Promise((r) => blocker.listen(port, "127.0.0.1", r));
  try {
    await assert.rejects(startStaticServer(root, { port }), (err) => {
      assert.equal(err.code, "OPENPLAY_PORT_IN_USE");
      assert.equal(err.port, port);
      assert.match(err.message, new RegExp(String(port)));
      return true;
    });
  } finally {
    await close(blocker);
  }
});
