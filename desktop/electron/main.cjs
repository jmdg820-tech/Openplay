// OpenPlay desktop -- Electron main process.
//
// Security posture (mirrors the Tournament Operator reference architecture):
//   contextIsolation: true, nodeIntegration: false, sandbox: true, a narrow
//   preload bridge, single-instance lock, navigation locked to the app's
//   own local origin, and all window.open()/new-window attempts denied.
//
// Renderer: the packaged Flutter Web build, served from a loopback-only
// local HTTP server on a fixed port (see server.cjs for why loadFile()/
// file:// was not used, and why the port must be stable across launches).

const path = require("path");
const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const { startStaticServer, resolvePort } = require("./server.cjs");
const updater = require("./updater.cjs");

const WEBAPP_DIR = path.join(__dirname, "..", "webapp");

let mainWindow = null;
let localServer = null;
let localOrigin = null;

function rendererPrefs() {
  return {
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: true,
    preload: path.join(__dirname, "preload.cjs"),
  };
}

function isAllowedNavigation(url) {
  if (!localOrigin) return false;
  return url === localOrigin || url.startsWith(`${localOrigin}/`);
}

function guardWindow(win) {
  // Block navigation to anything other than this app's own local origin.
  win.webContents.on("will-navigate", (event, url) => {
    if (!isAllowedNavigation(url)) {
      event.preventDefault();
    }
  });

  // Never let the renderer open new Electron windows. External-looking
  // links (http/https) are hop-out to the OS browser instead; everything
  // else is denied outright.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url) && !isAllowedNavigation(url)) {
      shell.openExternal(url);
    }
    return { action: "deny" };
  });
}

async function createMainWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 832,
    minWidth: 960,
    minHeight: 640,
    title: "OpenPlay",
    icon: path.join(__dirname, "..", "resources", "icon.ico"),
    backgroundColor: "#0E1A16",
    autoHideMenuBar: true,
    webPreferences: rendererPrefs(),
  });

  guardWindow(win);
  await win.loadURL(localOrigin);
  return win;
}

function registerIpc() {
  ipcMain.handle("desktop-info", () => ({
    runtime: "electron",
    version: app.getVersion(),
    packaged: app.isPackaged,
  }));

  ipcMain.handle("updater:get-state", () => updater.getState());
  ipcMain.handle("updater:check", () => {
    updater.check({ force: true });
    return updater.getState();
  });
  ipcMain.handle("updater:install", (event) => {
    // Defense in depth: only the main window may trigger an install, same
    // restriction Tournament applies to its pop-out windows.
    if (!mainWindow || event.sender !== mainWindow.webContents) return false;
    return updater.install();
  });
  ipcMain.handle("updater:later", () => {
    updater.later();
    return updater.getState();
  });
  ipcMain.on("updater:set-context", (_event, payload) => {
    updater.setContext(payload);
  });
}

async function main() {
  const gotLock = app.requestSingleInstanceLock();
  if (!gotLock) {
    app.quit();
    return;
  }

  app.on("second-instance", () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });

  await app.whenReady();

  let started;
  try {
    started = await startStaticServer(WEBAPP_DIR, { port: resolvePort() });
  } catch (err) {
    if (err && err.code === "OPENPLAY_PORT_IN_USE") {
      // Never fall back to another port: that would change the origin and
      // silently sign the user out (see server.cjs).
      dialog.showErrorBox(
        "OpenPlay can't start",
        `${err.message}\n\nClose the program using port ${err.port} and try again. ` +
          `If the port is reserved by Windows, set the OPENPLAY_DESKTOP_PORT environment ` +
          `variable to a free port (you will need to sign in again once).`
      );
      app.quit();
      return;
    }
    throw err;
  }
  const { server, port } = started;
  localServer = server;
  localOrigin = `http://127.0.0.1:${port}`;

  registerIpc();
  mainWindow = await createMainWindow();

  try {
    updater.attach(mainWindow);
  } catch (err) {
    console.warn("[updater] failed to attach:", err && err.message ? err.message : err);
  }

  app.on("activate", async () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      mainWindow = await createMainWindow();
      updater.attach(mainWindow);
    }
  });
}

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  if (localServer) {
    try {
      localServer.close();
    } catch {
      // best-effort
    }
  }
});

main().catch((err) => {
  console.error("[main] fatal error during startup:", err);
  app.quit();
});
