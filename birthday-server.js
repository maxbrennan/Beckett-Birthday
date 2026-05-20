const WebSocket = require('ws');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { Elm } = require('./elm-server.js');
const codec = require('./proto-codec.js');
const auth = require('./auth-helpers.js');

const STATE_FILE = path.join(__dirname, 'state.json');
const CERT_FILE = path.join(__dirname, 'certs', 'cert.pem');
const KEY_FILE = path.join(__dirname, 'certs', 'key.pem');

const app = Elm.Server.init();
const clients = new Map();
const pendingAuths = new Map();
let nextId = 0;

const server = https.createServer({
    cert: fs.readFileSync(CERT_FILE),
    key: fs.readFileSync(KEY_FILE),
});
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
    const clientId = String(nextId++);
    clients.set(clientId, ws);

    app.ports.onConnection.send(clientId);

    ws.on('message', (data) => {
        let msg;
        try {
            msg = codec.decodeClient(data);
        } catch (err) {
            console.error('Failed to decode ClientMessage:', err.message);
            return;
        }

        if (msg.payload === 'authResponse') {
            const pending = pendingAuths.get(clientId);
            if (!pending) return;
            pendingAuths.delete(clientId);
            const result = auth.handleAuthResponse(msg.authResponse, pending.challenge);
            ws.send(codec.encodeServer({ authResult: result }), { binary: true });
            const variant = result.password || result.key || {};
            app.ports.authResult.send({
                clientId,
                success: !!variant.success,
                level: variant.level || 0,
                uuid: variant.uuid || '',
            });
            return;
        }

        app.ports.onMessage.send({ clientId, payload: msg });
    });

    ws.on('close', () => {
        clients.delete(clientId);
        pendingAuths.delete(clientId);
        app.ports.onDisconnection.send(clientId);
    });
});

app.ports.sendToClient.subscribe(({ clientId, payload }) => {
    const ws = clients.get(clientId);
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(codec.encodeServer(payload), { binary: true });
});

app.ports.closeClient.subscribe(({ clientId, reason }) => {
    const ws = clients.get(clientId);
    if (ws) {
        try {
            ws.close(1000, reason);
        } catch (_) {}
        clients.delete(clientId);
    }
});

app.ports.saveState.subscribe((payload) => {
    fs.writeFile(STATE_FILE, JSON.stringify(payload, null, 2), (err) => {
        if (err) console.error('Failed to write state file:', err.message);
    });
});

app.ports.readFile.subscribe((filePath) => {
    const fullPath = path.isAbsolute(filePath) ? filePath : path.join(__dirname, filePath);
    fs.readFile(fullPath, 'utf8', (err, data) => {
        if (err) {
            app.ports.readFileResult.send({ path: filePath, contents: null, error: err.message });
        } else {
            app.ports.readFileResult.send({ path: filePath, contents: data, error: null });
        }
    });
});

const writeQueues = new Map();
app.ports.writeFile.subscribe(({ path: filePath, contents, encoding, append }) => {
    const fullPath = path.isAbsolute(filePath) ? filePath : path.join(__dirname, filePath);
    const prev = writeQueues.get(fullPath) || Promise.resolve();
    const next = prev.then(() => new Promise((resolve) => {
        fs.mkdir(path.dirname(fullPath), { recursive: true }, () => {
            const writer = append ? fs.appendFile : fs.writeFile;
            writer(fullPath, contents, encoding, (err) => {
                app.ports.writeFileResult.send({
                    path: filePath,
                    ok: !err,
                    error: err ? err.message : null,
                });
                resolve();
            });
        });
    }));
    writeQueues.set(fullPath, next);
});

app.ports.requestAuth.subscribe(({ clientId, level }) => {
    const ws = clients.get(clientId);
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const { challenge } = auth.generateAuthChallenge();
    pendingAuths.set(clientId, { challenge, level });
    ws.send(codec.encodeServer({
        authChallenge: { challenge, level },
    }), { binary: true });
});

wss.on('error', (err) => {
    console.error('WebSocket server error:', err.message);
    process.exit(1);
});

server.on('error', (err) => {
    console.error('HTTPS server error:', err.message);
    process.exit(1);
});

server.listen(443, '0.0.0.0', () => {
    console.log(`WebSocket server listening on wss://0.0.0.0`);
});

const shutdown = () => { wss.close(() => server.close(() => process.exit(0))); };
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.on('SIGHUP', () => {});
