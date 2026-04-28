const { execFile } = require('child_process')
const { existsSync } = require('fs')
const path = require('path')

const binary = path.join(__dirname, 'src', 'list_audio_devices')
const app = Elm.Main.init({ node: document.getElementById('app') })
let currentAudio = null
let currentAudioName = ''

function resolveAsset(filename) {
  return path.join(__dirname, 'assets', filename)
}

setInterval(() => {
  if (currentAudio && currentAudioName && !currentAudio.paused) {
    app.ports.receiveTrackInfo.send({
      name: currentAudioName,
      currentTime: currentAudio.currentTime,
      duration: currentAudio.duration || 0,
    })
  }
}, 100)

setInterval(() => {
  execFile(binary, (err, stdout) => {
    if (!err) {
      app.ports.receiveDevices.send(stdout)
    }
  })
}, 100)

app.ports.playMusic.subscribe((filename) => {
  if (!existsSync(resolveAsset(filename))) {
    app.ports.musicError.send(`File not found: ${filename}`)
    return
  }

  if (currentAudio) {
    currentAudio.onended = null
    currentAudio.pause()
    currentAudio = null
    currentName = ''
  }

  const audio = new Audio(`assets/${filename}`)
  currentAudio = audio
  currentName = filename

  audio.onended = () => {
    currentAudio = null
    currentName = ''
    app.ports.trackEnded.send(filename)
  }

  audio.play()
})

app.ports.stopMusic.subscribe((filename) => {
  if (!existsSync(resolveAsset(filename))) {
    app.ports.musicError.send(`File not found: ${filename}`)
    return
  }

  if (currentName === filename && currentAudio) {
    currentAudio.onended = null
    currentAudio.pause()
    currentAudio.currentTime = 0
    currentAudio = null
    currentName = ''
  }
})