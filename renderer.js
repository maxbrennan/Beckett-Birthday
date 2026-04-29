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
  app.ports.receiveTrackInfo.send(tracks)
}, 100)

setInterval(() => {
  execFile(binary, (err, stdout) => {
    if (!err) {
      app.ports.receiveDevices.send(stdout)
    }
  })
}, 100)

app.ports.playMusic.subscribe(({ filename, volume, startTime }) => {
  if (!existsSync(resolveAsset(filename))) {
    app.ports.musicError.send(`File not found: ${filename}`)
    return
  }

  const id = generateId()
  const audio = new Audio(`assets/${filename}`)
  audio.volume = volume

  audioMap.set(id, { element: audio, filename })

  audio.onended = () => {
    audioMap.delete(id)
    app.ports.trackEnded.send(filename)
  }

  if (startTime === 0) {
    audio.play()
  } else {
    audio.addEventListener('loadedmetadata', () => {
      if (startTime >= audio.duration) {
        audioMap.delete(id)
        app.ports.musicError.send(`Invalid start time ${startTime} for ${filename}`)
        return
      }
      audio.currentTime = startTime
      audio.play()
    }, { once: true })
  }

  app.ports.musicStarted.send({ id, filename })
})

app.ports.stopMusic.subscribe((id) => {
  const entry = audioMap.get(id)
  if (!entry) return

  audioMap.delete(id)
  entry.element.onended = null
  entry.element.pause()
})
