const { app, BrowserWindow } = require('electron')

app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')
const { execFile } = require('child_process')
const path = require('path')

function createWindow() {
  const win = new BrowserWindow({
    width: 900,
    height: 600,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
  })

  win.loadFile('index.html')

  const binary = path.join(__dirname, 'src', 'list_audio_devices')

  function poll() {
    execFile(binary, (err, stdout) => {
      if (!err && !win.isDestroyed()) {
        win.webContents.send('devices', stdout)
      }
      if (!win.isDestroyed()) setTimeout(poll, 20)
    })
  }

  win.webContents.once('did-finish-load', poll)
}

app.whenReady().then(createWindow)
app.on('window-all-closed', () => app.quit())
