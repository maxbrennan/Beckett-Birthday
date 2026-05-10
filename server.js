const WebSocket = require('ws');
const { Elm } = require('./elm-server.js');

const app = Elm.Server.init();
const clients = new Map();
let nextId = 0;

const wss = new WebSocket.Server({ host: 'localhost', port: 5270 });

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

    ws.on('close', () => clients.delete(clientId));
});

app.ports.sendToClient.subscribe(({ clientId, payload }) => {
    const ws = clients.get(clientId);
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(payload));
    }
});

console.log('WebSocket server listening on ws://localhost:5270');
