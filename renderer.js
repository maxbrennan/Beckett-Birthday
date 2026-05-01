const { execFile } = require('child_process')
const { existsSync, appendFileSync, writeFileSync } = require('fs')
const path = require('path')
const Ws = require('ws')

const binary = path.join(__dirname, 'src', 'list_audio_devices')
const logPath = path.join(__dirname, 'debug.log')
const app = Elm.Main.init({ node: document.getElementById('app') })

app.ports.logToFile.subscribe((entry) => {
  appendFileSync(logPath, entry + '\n', 'utf8')
})

const silenceLoop = new Audio('assets/silence.mp3')
silenceLoop.loop = true
silenceLoop.play()

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
  const ws = new Ws(url)
  let failedFired = false
  let isAlive = false
  let heartbeatTimer = null

  const fireFailed = (reason) => {
    if (!failedFired) {
      console.log(`WebSocket ${id} failed: ${reason}`)
      failedFired = true
      if (heartbeatTimer) clearInterval(heartbeatTimer)
      wsMap.delete(id)
      try { ws.terminate() } catch (_) {}
      app.ports.wsClientFailed.send(reason)
    }
  }

  ws.on('open', () => {
    console.log(`WebSocket ${id} connected successfully`)
    isAlive = true
    wsMap.set(id, ws)
    app.ports.wsClientReady.send(id)

    heartbeatTimer = setInterval(() => {
      if (!isAlive) {
        fireFailed('heartbeat timeout')
        return
      }
      isAlive = false
      ws.ping()
    }, 3000)
  })

  ws.on('pong', () => {
    isAlive = true
    app.ports.wsPong.send(0)
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
