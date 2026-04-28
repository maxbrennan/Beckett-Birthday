const { execFile } = require('child_process')
const { BrowserWindow } = require('electron')
const path = require('path')

const binary = path.join(__dirname, 'src', 'list_audio_devices')
let running = false

async function continuouslySendDeviceInfo() {
  while (running) {
    await new Promise((resolve) => {
      execFile(binary, (err, stdout) => {
        if (!err) {
          BrowserWindow.getAllWindows().forEach((win) => {
            if (!win.isDestroyed()) win.webContents.send('devices', stdout)
          })
        }
      })
      setTimeout(resolve, 20)
    })
  }
}

function startPorts() {
  running = true
  continuouslySendDeviceInfo()
}

function stopPorts() {
  running = false
}

module.exports = { startPorts, stopPorts }
