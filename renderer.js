const { execFile } = require('child_process')
const { existsSync, appendFileSync, writeFileSync } = require('fs')
const path = require('path')

const logPath = path.join(__dirname, 'debug.log')
writeFileSync(logPath, '', 'utf8')

const binary = path.join(__dirname, 'src', 'list_audio_devices')
const app = Elm.Main.init({ node: document.getElementById('app') })

app.ports.logToFile.subscribe((entry) => {
  appendFileSync(logPath, entry + '\n', 'utf8')
})

// id -> { element: Audio, filename: String }
const audioMap = new Map()
let nextId = 0
const generateId = () => String(nextId++)

function resolveAsset(filename) {
  return path.join(__dirname, 'assets', filename)
}

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

setInterval(() => {
  execFile(binary, (err, stdout) => {
    if (!err) {
      app.ports.receiveDevices.send(stdout)
    }
  })
}, 100)

app.ports.loadMusic.subscribe((filename) => {
  if (!existsSync(resolveAsset(filename))) {
    app.ports.musicError.send(`File not found: ${filename}`)
    return
  }

  const id = generateId()
  const audio = new Audio(`assets/${filename}`)
  audio.preload = 'auto'

  audio.onended = () => {
    if (filename !== 'ding.mp3') {
      audioMap.delete(id)
    }
    app.ports.trackEnded.send(filename)
  }

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

app.ports.seekVideo.subscribe((time) => {
  console.log(`seekVideo: requested time=${time}`)
  const trySeek = (retriesLeft) => {
    const videoEl = document.getElementById('playing-video')
    if (!videoEl) {
      if (retriesLeft > 0) setTimeout(() => trySeek(retriesLeft - 1), 50)
      else console.log('seekVideo: element never found')
      return
    }
    if (videoEl.readyState >= 1) {
      console.log(`seekVideo: seeking to ${time} (readyState=${videoEl.readyState})`)
      videoEl.currentTime = time
    } else {
      console.log(`seekVideo: waiting for loadedmetadata (readyState=${videoEl.readyState})`)
      videoEl.addEventListener('loadedmetadata', () => {
        console.log(`seekVideo: loadedmetadata fired, seeking to ${time}`)
        videoEl.currentTime = time
      }, { once: true })
    }
  }
  setTimeout(() => trySeek(40), 0)
})

app.ports.stopMusic.subscribe((id) => {
  const entry = audioMap.get(id)
  if (!entry) return

  audioMap.delete(id)
  entry.element.onended = null
  entry.element.pause()
})

// WebSocket management
const wsMap = new Map()
let nextWsId = 0
const generateWsId = () => String(nextWsId++)

app.ports.initWebSocketClient.subscribe((url) => {
  console.log(`Initializing WebSocket client with URL: ${url}`)
  const id = generateWsId()
  const ws = new WebSocket(url)
  let failedFired = false

  const fireFailed = (reason) => {
    if (!failedFired) {
      console.log(`WebSocket ${id} failed: ${reason}`)
      failedFired = true
      wsMap.delete(id)
      app.ports.wsClientFailed.send(reason)
    }
  }

  ws.onopen = () => {
    console.log(`WebSocket ${id} connected successfully`)
    wsMap.set(id, ws)
    app.ports.wsClientReady.send(id)
  }

  ws.onmessage = (event) => {
    app.ports.receiveFromWs.send(event.data)
  }

  ws.onclose = () => {
    fireFailed('closed')
  }

  ws.onerror = () => {
    fireFailed('error')
  }
})

app.ports.sendToWs.subscribe(({ wsId, data }) => {
  const ws = wsMap.get(wsId)
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(data)
  }
})
