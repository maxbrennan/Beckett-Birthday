const Ws = require('ws')
const codec = require('./proto-codec.js')

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
    let msg
    try {
      msg = codec.decodeServer(data)
    } catch (err) {
      console.error('Failed to decode ServerMessage:', err.message)
      return
    }
    switch (msg.payload) {
      case 'stateUpdate':
        app.ports.receiveFromWs.send(msg.stateUpdate.json)
        if (!received) {
          console.log(`WebSocket ${id} received first message: ${msg.stateUpdate.json}`)
          received = true
        }
        break
      case 'ack':
        app.ports.receiveFromWs.send('{"tag":"ack"}')
        break
      case 'authChallenge':
      case 'authResult':
      case 'permissionDenied':
        console.log(`Received ${msg.payload} (handler not implemented)`)
        break
      default:
        console.warn('Unknown ServerMessage payload:', msg.payload)
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
    const buf = codec.encodeClient({ stateUpdate: { json: data } })
    ws.send(buf, { binary: true })
  }
})
