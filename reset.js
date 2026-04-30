const WebSocket = require('ws')

const ws = new WebSocket('ws://72.211.182.145:5270')

ws.on('open', () => {
  ws.send('{}')
  ws.close()
})

ws.on('error', (err) => {
  console.error('Connection failed:', err.message)
  process.exit(1)
})

ws.on('close', () => {
  console.log('Reset sent.')
})
