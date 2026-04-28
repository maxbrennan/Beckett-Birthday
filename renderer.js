const { existsSync } = require('fs')
const path = require('path')

// Audio management
let running = true
let currentAudio = null
let currentName = ''
const binary = path.join(__dirname, 'src', 'list_audio_devices')

function resolveAsset(filename) {
  return path.join(__dirname, 'assets', filename)
}

async function continuouslySendAudioInfo() {
  while (true) {
    if (currentAudio && currentName && !currentAudio.paused) {
      app.ports.receiveTrackInfo.send({
        name: currentName,
        currentTime: currentAudio.currentTime,
        duration: currentAudio.duration || 0,
      })
    }
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
}

async function continuouslySendDeviceInfo() {
  while (true) {
    execFile(binary, (err, stdout) => {
      if (!err) {
        app.ports.receiveDevices.send(stdout)
      }
    })
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
}

async function startProgram() {
  println('Starting program...')
  initializePorts()
  await Promise.all([continuouslySendAudioInfo(), continuouslySendDeviceInfo()])
}

function initializePorts() {
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
}

startProgram()