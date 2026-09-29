// Preload script -- runs in an isolated context (contextIsolation: true)
// with no Node integration in the renderer. Exposes one narrow, explicit
// global via contextBridge; nothing else from Node/Electron is reachable
// from the Flutter Web app. No secrets are exposed here.

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("openplayDesktop", {
  runtime: "electron",
  getInfo: () => ipcRenderer.invoke("desktop-info"),
  updates: {
    getState: () => ipcRenderer.invoke("updater:get-state"),
    check: () => ipcRenderer.invoke("updater:check"),
    install: () => ipcRenderer.invoke("updater:install"),
    later: () => ipcRenderer.invoke("updater:later"),
    setContext: (payload) => ipcRenderer.send("updater:set-context", payload),
    onStatus: (callback) => {
      const listener = (_event, state) => callback(state);
      ipcRenderer.on("updater:status", listener);
      return () => ipcRenderer.removeListener("updater:status", listener);
    },
  },
});
