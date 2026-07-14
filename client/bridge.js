const path = require('path')

function computeWsUrl(env) {
  const isDev = env.DEV === 'true'
  const host = isDev ? 'localhost' : env.PROD_SERVER_HOST
  const port = isDev ? env.DEV_SERVER_PORT : env.PROD_SERVER_PORT
  return port === '443' ? `wss://${host}` : `wss://${host}:${port}`
}

function resolveReadFilePath(filePath, baseDir) {
  return path.isAbsolute(filePath) ? filePath : path.join(baseDir, filePath)
}

function decodeIncomingWsMessage(data, codecImpl) {
  const msg = codecImpl.decodeServer(data)
  return JSON.stringify(msg)
}

function handleReadFileResult(err, data, filePath) {
  return err
    ? { path: filePath, contents: null, error: err.message }
    : { path: filePath, contents: data, error: null }
}

// The client no longer reads any config/ JSON for the quiz (see #54, #70's review) --
// it discovers songs by listing assets/songs/ directly and orders them by the numeric
// filename convention (see Game.Quiz.elm's songOrder), so nothing under config/ needs
// to be bundled or read client-side at all.
function handleReadDirResult(err, files, dirPath) {
  return err
    ? { path: dirPath, files: [], error: err.message }
    : { path: dirPath, files: files || [], error: null }
}

// Mirrors server/index.js's writeFile port handler, minus its write queue -- this
// is only ever used for the local IQ-offer-grant cache (a single small file with
// no concurrent writers, and a pure rendering accelerator, not authoritative
// state -- see Main.elm's offerGrantCachePath), so a rare interleaved write just
// means a stale cache that self-heals on the next successful server reconcile.
// Named writeCacheFile (not writeFile) to avoid an elm-test port-name collision
// with Server.elm's own writeFile port -- see Main.elm's port declaration comment.
function handleWriteCacheFileResult(err, filePath) {
  return { path: filePath, ok: !err, error: err ? err.message : null }
}

module.exports = { computeWsUrl, resolveReadFilePath, decodeIncomingWsMessage, handleReadFileResult, handleReadDirResult, handleWriteCacheFileResult }

// Loaded via a plain <script src="client/bridge.js"> tag in index.html (nodeIntegration
// on, contextIsolation off) rather than as a required CommonJS module — Electron resolves
// `require`/`__dirname` here relative to index.html's directory (the project root), not
// this file's own location, which is why the requires below use paths that look wrong for
// a file physically under client/. That quirk only matters once a real DOM exists, so
// gating it here also lets the pure helpers above be required directly by Jest.
if (typeof document !== 'undefined') {
  const Ws = require('ws')
  const fs = require('fs')
  require('dotenv').config({ path: path.join(__dirname, '.env') })
  const codec = require('./server/codec.js')

  const wsUrl = computeWsUrl(process.env)
  const app = Elm.Main.init({ node: document.getElementById('app'), flags: wsUrl })
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
    const ws = new Ws(url, { rejectUnauthorized: false }) // TODO remove rejectUnauthorized in production with valid certs

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
      let encoded
      try {
        encoded = decodeIncomingWsMessage(data, codec)
      } catch (err) {
        console.error('Failed to decode ServerMessage:', err.message)
        return
      }
      app.ports.receiveFromWs.send(encoded)
      if (!received) {
        console.log(`WebSocket ${id} received first message: ${encoded}`)
        received = true
      }
    })

    ws.on('close', (code, reason) => {
      fireFailed(`closed ${reason.toString()} (code ${code})`)
    })

    ws.on('error', (error) => {
      fireFailed(`error ${error.message}`)
    })
  })

  app.ports.sendToWs.subscribe(({ wsId, data }) => {
    const ws = wsMap.get(wsId)
    if (ws && ws.readyState === Ws.OPEN) {
      ws.send(codec.encodeClient(JSON.parse(data)), { binary: true })
    }
  })

  app.ports.readFile.subscribe((filePath) => {
    const fullPath = resolveReadFilePath(filePath, __dirname)
    fs.readFile(fullPath, 'utf8', (err, data) => {
      app.ports.readFileResult.send(handleReadFileResult(err, data, filePath))
    })
  })

  app.ports.readDir.subscribe((dirPath) => {
    const fullPath = resolveReadFilePath(dirPath, __dirname)
    fs.readdir(fullPath, (err, files) => {
      app.ports.readDirResult.send(handleReadDirResult(err, files, dirPath))
    })
  })

  app.ports.writeCacheFile.subscribe(({ path: filePath, contents, encoding, append }) => {
    const fullPath = resolveReadFilePath(filePath, __dirname)
    fs.mkdir(path.dirname(fullPath), { recursive: true }, () => {
      const writer = append ? fs.appendFile : fs.writeFile
      writer(fullPath, contents, encoding, (err) => {
        app.ports.writeCacheFileResult.send(handleWriteCacheFileResult(err, filePath))
      })
    })
  })
}
