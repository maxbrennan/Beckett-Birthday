const { ipcRenderer } = require('electron')

window.__registerDeviceListener = (callback) => {
  ipcRenderer.on('devices', (_event, data) => callback(data))
}
