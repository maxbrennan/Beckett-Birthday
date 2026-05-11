const Ws = require('ws')

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
  const ws = new Ws(url)

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
    app.ports.receiveFromWs.send(data.toString())
    if (!received) {
      console.log(`WebSocket ${id} received first message: ${data.toString()}`)
      received = true
    }
  })

  ws.on('close', () => {
    fireFailed('closed')
  })

  ws.on('error', () => {
    fireFailed('error')
  })
})

app.ports.sendToWs.subscribe(({ wsId, data }) => {
  const ws = wsMap.get(wsId)
  if (ws && ws.readyState === Ws.OPEN) {
    ws.send(data)
  }
})
