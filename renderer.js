const { execFile } = require('child_process')
const { existsSync, appendFileSync, writeFileSync, promises } = require('fs')
const path = require('path')
const Ws = require('ws')

const app = Elm.Main.init({ node: document.getElementById('app') })

// id -> { element: Audio, filename: String }
const audioMap = new Map()
let nextId = 0
const generateId = () => String(nextId++)

setInterval(() => {
  const tracks = []
  for (const [id, entry] of audioMap) {
    tracks.push({
      id,
      currentTime: entry.element.currentTime,
      duration: entry.element.duration || 0,
    })
  }
  const videoEl = document.getElementById('playing-video')
  if (videoEl) {
    tracks.push({
      id: 'video',
      currentTime: videoEl.currentTime,
      duration: videoEl.duration || 0,
    })
  }
  app.ports.receiveTrackInfo.send(tracks)
}, 100)

app.ports.loadMusic.subscribe(async (filename) => {
  try {
    await promises.access(resolveAsset(filename))
  } catch (err) {
    app.ports.musicError.send(`File not found: ${filename}`)
    return
  }

  const id = generateId()
  const audio = new Audio(`${filename}`)
  audio.preload = 'auto'

  audioMap.set(id, { element: audio, filename })
  app.ports.musicLoaded.send({ id, filename })
})

app.ports.playMusic.subscribe(({ id, volume, startTime }) => {
  const entry = audioMap.get(id)
  if (!entry) {
    app.ports.musicError.send(`No audio loaded with id: ${id}`)
    return
  }
  const audio = entry.element
  audio.volume = volume
  const doPlay = () => {
    if (startTime > 0 && startTime >= audio.duration) {
      app.ports.musicError.send(`Invalid start time ${startTime} for ${entry.filename}`)
      return
    }
    audio.currentTime = startTime
    audio.play()
  }
  if (startTime === 0 || audio.readyState >= 1) {
    doPlay()
  } else {
    audio.addEventListener('loadedmetadata', doPlay, { once: true })
  }
})

app.ports.setVideoTimestamp.subscribe(({ elementId, time }) => {
  const videoEl = document.getElementById(elementId)
  if (!videoEl) {
    // TODO send error to elm
    console.log('failed to find video element with id:', elementId)
    return
  }
  videoEl.currentTime = time
})

app.ports.pauseMusic.subscribe((id) => {
  const entry = audioMap.get(id)
  if (!entry) return

  entry.element.pause()
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
