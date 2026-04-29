const { execFile } = require('child_process')
const { existsSync } = require('fs')
const path = require('path')

const binary = path.join(__dirname, 'src', 'list_audio_devices')
const app = Elm.Main.init({ node: document.getElementById('app') })

const flashOverlay = document.createElement('div')
flashOverlay.style.cssText = `
  position: fixed;
  top: 0; left: 0;
  width: 100vw; height: 100vh;
  background: #00cc44;
  z-index: 9999;
  pointer-events: none;
  display: none;
`
document.body.appendChild(flashOverlay)

app.ports.showFlash.subscribe((on) => {
  flashOverlay.style.display = on ? 'block' : 'none'
})
let currentAudio = null
let currentAudioName = ''
let currentVideo = null
let currentVideoName = ''

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
    currentAudioName = ''
  }

  if (currentVideo) {
    currentVideo.onended = null
    currentVideo.pause()
    currentVideo.remove()
    currentVideo = null
    currentVideoName = ''
  }

  const audio = new Audio(`assets/${filename}`)
  currentAudio = audio
  currentAudioName = filename

  audio.onended = () => {
    currentAudio = null
    currentAudioName = ''
    app.ports.trackEnded.send(filename)
  }

  audio.play()
})

app.ports.playVideo.subscribe(({ filename, loop }) => {
  if (!existsSync(resolveAsset(filename))) {
    app.ports.musicError.send(`File not found: ${filename}`)
    return
  }

  if (currentAudio) {
    currentAudio.onended = null
    currentAudio.pause()
    currentAudio = null
    currentAudioName = ''
  }

  if (currentVideo) {
    currentVideo.onended = null
    currentVideo.pause()
    currentVideo.remove()
    currentVideo = null
    currentVideoName = ''
  }

  const video = document.createElement('video')
  video.src = `assets/${filename}`
  video.controls = false
  video.autoplay = true
  video.loop = loop
  // Loop videos sit behind the Elm app (z-index 1); foreground videos sit above it
  video.style.cssText = `
    position: fixed;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    width: 100vw;
    height: 100vh;
    object-fit: contain;
    z-index: ${loop ? 0 : 2};
  `
  document.body.appendChild(video)
  document.body.style.backgroundColor = '#000000'
  currentVideo = video
  currentVideoName = filename

  if (!loop) {
    video.onended = () => {
      video.remove()
      document.body.style.backgroundColor = '#a8c8e0'
      currentVideo = null
      currentVideoName = ''
      app.ports.trackEnded.send(filename)
    }
  }
})

app.ports.playDing.subscribe((volume) => {
  const audio = new Audio('assets/ding.mp3')
  audio.volume = volume
  audio.play()
})

app.ports.stopMusic.subscribe((filename) => {
  if (!existsSync(resolveAsset(filename))) {
    app.ports.musicError.send(`File not found: ${filename}`)
    return
  }

  if (filename.endsWith('.mp4')) {
    if (currentVideoName === filename && currentVideo) {
      currentVideo.onended = null
      currentVideo.pause()
      currentVideo.remove()
      currentVideo = null
      currentVideoName = ''
    }
  } else {
    if (currentAudioName === filename && currentAudio) {
      currentAudio.onended = null
      currentAudio.pause()
      currentAudio.currentTime = 0
      currentAudio = null
      currentAudioName = ''
    }
  }
})
