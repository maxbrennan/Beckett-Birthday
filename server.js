const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { Elm } = require('./elm-server.js');

try { execSync('lsof -ti:5270 | xargs kill'); } catch (_) {}

const STATE_FILE = path.join(__dirname, 'state.json');

const app = Elm.Server.init();
const clients = new Map();
let nextId = 0;

const wss = new WebSocket.Server({ host: '0.0.0.0', port: 5270 });

wss.on('connection', (ws) => {
    const clientId = String(nextId++);
    clients.set(clientId, ws);

    app.ports.onConnection.send(clientId);

    ws.on('message', (data) => {
        let parsed;
        try {
            parsed = JSON.parse(data.toString());
        } catch (_) {
            return;
        }
        app.ports.onMessage.send({ clientId, payload: parsed });
    });

    ws.on('close', () => {
        clients.delete(clientId);
        app.ports.onDisconnection.send(clientId);
    });
});

app.ports.sendToClient.subscribe(({ clientId, payload }) => {
    const ws = clients.get(clientId);
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(payload));
    }
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
    if (err.code === 'EADDRINUSE') {
        console.error('Port 5270 already in use. Kill the old process: lsof -ti:5270 | xargs kill');
    } else {
        console.error('WebSocket server error:', err.message);
    }
    process.exit(1);
});

console.log('WebSocket server listening on ws://0.0.0.0:5270');

const shutdown = () => wss.close(() => process.exit(0));
process.on('SIGINT', shutdown);
process.on('SIGHUP', () => {});
