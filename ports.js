const audio = new Audio('assets/jeopardy-theme.mp3')
audio.loop = true
audio.play()

window.electronAPI.onDevices((data) => {
  app.ports.receiveDevices.send(data)
})

app.ports.stopMusic.subscribe(() => {
  audio.pause()
  audio.currentTime = 0
})

app.ports.restartMusic.subscribe(() => {
  audio.currentTime = 0
  audio.play()
})
