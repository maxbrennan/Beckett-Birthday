const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('electronAPI', {
  onDevices: (callback) =>
    ipcRenderer.on('devices', (_event, data) => callback(data)),
})
