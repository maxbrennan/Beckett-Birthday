const { app, BrowserWindow } = require('electron')
const path = require('path')

app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')

function createWindow() {
  const win = new BrowserWindow({
    width: 900,
    height: 600,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
    },
  })

  win.loadFile('index.html')
  console.log(`[DEV] DEV mode is ${process.env.DEV}`)
  if (process.env.DEV === 'true') win.webContents.openDevTools({ mode: 'detach' });
}

app.whenReady().then(() => {
  createWindow()
})

app.on('window-all-closed', () => {
  app.quit()
})
