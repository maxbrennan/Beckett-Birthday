const Ws = require('ws')
const fs = require('fs')
const path = require('path')
const codec = require('./server/codec.js')

const app = Elm.Main.init({ node: document.getElementById('app') })
let received = false

app.ports.setDomProperty.subscribe(({ elementId, property, value }) => {
  const el = document.getElementById(elementId)
  if (!el) {
    app.ports.domPropertyError.send(`Element not found: ${elementId}`)
    return
  }
  try {
    el[property] = value
  } catch (e) {
    app.ports.domPropertyError.send(`Failed to set ${property} on ${elementId}: ${e.message}`)
  }
})

// app.ports.getDomProperty.subscribe(({ elementId, property }) => {
//   const el = document.getElementById(elementId)
//   if (!el) {
//     app.ports.domPropertyError.send(`Element not found: ${elementId}`)
//     return
//   }
//   app.ports.receiveDomProperty.send({ elementId, property, value: el[property] })
// })

app.ports.pauseMusic.subscribe((elementId) => {
  const el = document.getElementById(elementId)
  if (el) el.pause()
})

// WebSocket management
const wsMap = new Map()
let nextWsId = 0
const generateWsId = () => String(nextWsId++)

app.ports.initWebSocketClient.subscribe((url) => {
  console.log(`Initializing WebSocket client with URL: ${url}`)
  const id = generateWsId()
  const ws = new Ws(url, { rejectUnauthorized: false }) // TODO remove rejectUnauthorized in production with valid certs

  const fireFailed = (reason) => {
    console.log(`WebSocket ${id} failed: ${reason}`)
    wsMap.delete(id)
    try { ws.terminate() } catch (_) {}
    app.ports.wsClientFailed.send(reason)
  }

  ws.on('open', () => {
    console.log(`WebSocket ${id} connected successfully`)
    wsMap.set(id, ws)
    app.ports.wsClientReady.send(id)
  })

  ws.on('message', (data) => {
    let msg
    try {
      msg = codec.decodeServer(data)
    } catch (err) {
      console.error('Failed to decode ServerMessage:', err.message)
      return
    }
    const encoded = JSON.stringify(msg)
    app.ports.receiveFromWs.send(encoded)
    if (!received) {
      console.log(`WebSocket ${id} received first message: ${encoded}`)
      received = true
    }
  })

  ws.on('close', (code, reason) => {
    fireFailed(`closed ${reason.toString()} (code ${code})`)
  })

  ws.on('error', (error) => {
    fireFailed(`error ${error.message}`)
  })
})

app.ports.sendToWs.subscribe(({ wsId, data }) => {
  const ws = wsMap.get(wsId)
  if (ws && ws.readyState === Ws.OPEN) {
    ws.send(codec.encodeClient(JSON.parse(data)), { binary: true })
  }
})

app.ports.readFile.subscribe((filePath) => {
  const fullPath = path.isAbsolute(filePath) ? filePath : path.join(__dirname, filePath)
  fs.readFile(fullPath, 'utf8', (err, data) => {
    if (err) {
      app.ports.readFileResult.send({ path: filePath, contents: null, error: err.message })
    } else {
      app.ports.readFileResult.send({ path: filePath, contents: data, error: null })
    }
  })
})
