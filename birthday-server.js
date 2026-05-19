const WebSocket = require('ws');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { Elm } = require('./elm-server.js');
const codec = require('./proto-codec.js');

const STATE_FILE = path.join(__dirname, 'state.json');
const CERT_FILE = path.join(__dirname, 'certs', 'cert.pem');
const KEY_FILE = path.join(__dirname, 'certs', 'key.pem');

const app = Elm.Server.init();
const clients = new Map();
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
        app.ports.onMessage.send({ clientId, payload: msg });
    });

    ws.on('close', () => {
        clients.delete(clientId);
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
