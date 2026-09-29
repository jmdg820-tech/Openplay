// Minimal static file server for the packaged Flutter Web build, bound to
// the loopback interface only (127.0.0.1) on a FIXED port.
//
// Why a fixed port (audit finding): the renderer's origin is
// http://127.0.0.1:<port>, and everything the Flutter Web app persists --
// most importantly the Supabase auth session in localStorage -- is scoped to
// that exact origin. The previous OS-assigned ephemeral port gave the app a
// new origin on every launch, so every restart looked like a fresh browser
// profile and signed the user out. A stable port keeps the origin (and the
// saved sign-in) identical across launches.
//
// If the port is taken by another program, startup FAILS with a clear,
// typed error (code "OPENPLAY_PORT_IN_USE") instead of silently moving to a
// different port -- silently changing the origin would reintroduce exactly
// the sign-out bug this fixes. main.cjs turns that error into a dialog.
//
// Why a local HTTP server instead of BrowserWindow.loadFile() on file://:
// Flutter Web's --base-href must be an absolute path ("/"), so every asset
// reference in the build (main.dart.js, /assets/..., /canvaskit/...) is
// root-absolute. There is no "root" for file:// to resolve those against.
// A loopback HTTP server gives the app a real origin whose "/" is the
// build's own document root, exactly like any normal web deployment.
// It also makes http://127.0.0.1 a secure context (confirmed empirically:
// window.isSecureContext === true, navigator.geolocation and
// navigator.serviceWorker both available), which file:// is not.
//
// No third-party dependency is used here (plain Node "http"/"fs"), which
// keeps the Electron shell's own dependency surface minimal.

const http = require("http");
const fs = require("fs");
const path = require("path");

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".webmanifest": "application/manifest+json",
};

// The app's permanent local port. Changing it changes the origin, which
// discards every user's saved sign-in once -- do not change it casually.
const DEFAULT_PORT = 47823;

/**
 * Resolves the port to use: OPENPLAY_DESKTOP_PORT (for a machine where the
 * default is taken by another program -- note that switching ports resets
 * the saved sign-in once) or DEFAULT_PORT. Invalid values fall back to the
 * default rather than to a random port.
 */
function resolvePort(env = process.env) {
  const raw = env.OPENPLAY_DESKTOP_PORT;
  const n = Number(raw);
  if (raw && Number.isInteger(n) && n >= 1024 && n <= 65535) return n;
  return DEFAULT_PORT;
}

/**
 * Starts a loopback-only static file server for `rootDir` on `port`.
 * Resolves with the server instance and the port it bound to. Rejects with
 * an Error whose `code` is "OPENPLAY_PORT_IN_USE" if the port is occupied --
 * never falls back to a different port.
 */
function startStaticServer(rootDir, { port = DEFAULT_PORT } = {}) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      try {
        const urlPath = decodeURIComponent(req.url.split("?")[0]);
        let filePath = path.join(rootDir, urlPath);

        // Prevent path traversal outside rootDir.
        if (!filePath.startsWith(rootDir)) {
          res.writeHead(403);
          res.end("Forbidden");
          return;
        }

        if (urlPath === "/" || urlPath === "") {
          filePath = path.join(rootDir, "index.html");
        }

        fs.stat(filePath, (statErr, stats) => {
          if (statErr || !stats.isFile()) {
            // SPA-style fallback for any non-file route -- safe no-op for
            // this app today (it does not use URL-path-based routing), but
            // correct if that ever changes.
            const fallback = path.join(rootDir, "index.html");
            fs.readFile(fallback, (fallbackErr, data) => {
              if (fallbackErr) {
                res.writeHead(404);
                res.end("Not found");
                return;
              }
              res.writeHead(200, { "Content-Type": MIME_TYPES[".html"] });
              res.end(data);
            });
            return;
          }

          const ext = path.extname(filePath).toLowerCase();
          const contentType = MIME_TYPES[ext] || "application/octet-stream";
          res.writeHead(200, { "Content-Type": contentType });
          fs.createReadStream(filePath).pipe(res);
        });
      } catch (err) {
        res.writeHead(500);
        res.end("Internal error");
      }
    });

    server.on("error", (err) => {
      // EADDRINUSE: another program holds the port. EACCES: on Windows, the
      // port falls inside a range reserved by Hyper-V/WinNAT
      // (`netsh int ipv4 show excludedportrange protocol=tcp`). Both mean
      // "this fixed port is unavailable here" and get the same clear error.
      if (err && (err.code === "EADDRINUSE" || err.code === "EACCES")) {
        const inUse = new Error(
          `Local port ${port} is unavailable (in use by another program or reserved by Windows). ` +
            `OpenPlay needs this fixed port so your sign-in is remembered between launches.`
        );
        inUse.code = "OPENPLAY_PORT_IN_USE";
        inUse.port = port;
        reject(inUse);
        return;
      }
      reject(err);
    });
    // 127.0.0.1 only, never 0.0.0.0 -- this server must never be reachable
    // from outside the local machine.
    server.listen(port, "127.0.0.1", () => {
      resolve({ server, port: server.address().port });
    });
  });
}

module.exports = { startStaticServer, resolvePort, DEFAULT_PORT };
