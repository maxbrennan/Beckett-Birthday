const WebSocket = require('ws');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { Elm } = require('../elm-server.js');
const codec = require('./codec.js');
const auth = require('./auth.js');

const DOMAIN = 'brennanfamily.mynetgear.com';

const app = Elm.Server.init();
const clients = new Map();
const pendingAuths = new Map();
const pendingUndeployOps = new Map();
let nextId = 0;

const tlsOptions = process.env.DEV === 'true'
    ? {
        cert: fs.readFileSync(path.join(__dirname, '..', 'certs', 'cert.pem')),
        key: fs.readFileSync(path.join(__dirname, '..', 'certs', 'key.pem')),
    }
    : {
        cert: fs.readFileSync(`/etc/letsencrypt/live/${DOMAIN}/fullchain.pem`),
        key: fs.readFileSync(`/etc/letsencrypt/live/${DOMAIN}/privkey.pem`),
    };
const server = https.createServer(tlsOptions);
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

            if (pendingUndeployOps.has(clientId)) {
                const undeployUuid = pendingUndeployOps.get(clientId);
                pendingUndeployOps.delete(clientId);
                if (variant.success) {
                    performUndeploy(undeployUuid, ws);
                } else {
                    console.error(`[undeploy] auth failed for ${undeployUuid}`);
                    ws.close();
                }
                return;
            }

            app.ports.authResult.send({
                clientId,
                success: !!variant.success,
                level: variant.level || 0,
                uuid: variant.uuid || '',
            });
            return;
        }

        if (msg.payload === 'distUndeploy') {
            const { uuid } = msg.distUndeploy;
            console.log(`[undeploy] received request for ${uuid}`);
            pendingUndeployOps.set(clientId, uuid);
            const { challenge } = auth.generateAuthChallenge();
            pendingAuths.set(clientId, { challenge, level: 2 });
            ws.send(codec.encodeServer({ authChallenge: { challenge, level: 2 } }), { binary: true });
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

app.ports.readFile.subscribe((filePath) => {
    const fullPath = path.isAbsolute(filePath) ? filePath : path.join(__dirname, '..', filePath);
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
    const fullPath = path.isAbsolute(filePath) ? filePath : path.join(__dirname, '..', filePath);
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

const REGISTRY_FILE = path.join(__dirname, '..', 'releases', 'manifest.jsonl');
const BUILDS_DIR = path.join(__dirname, '..', 'releases');

function performUndeploy(uuid, ws) {
    fs.readFile(REGISTRY_FILE, 'utf8', (err, data) => {
        if (err) {
            console.error(`[undeploy] failed to read registry: ${err.message}`);
            ws.send(codec.encodeServer({ ack: {} }), { binary: true });
            ws.close();
            return;
        }
        const entries = data.trim().split('\n')
            .map(line => { try { return JSON.parse(line); } catch (_) { return null; } })
            .filter(Boolean);
        const target = entries.find(e => e.uuid === uuid);
        const remaining = entries.filter(e => e.uuid !== uuid);
        const newContent = remaining.map(e => JSON.stringify(e)).join('\n') + (remaining.length > 0 ? '\n' : '');
        fs.writeFile(REGISTRY_FILE, newContent, 'utf8', (writeErr) => {
            if (writeErr) console.error(`[undeploy] failed to write registry: ${writeErr.message}`);
            if (target) {
                const filePath = path.join(BUILDS_DIR, target.filename);
                fs.unlink(filePath, (unlinkErr) => {
                    if (unlinkErr) console.error(`[undeploy] failed to delete file: ${unlinkErr.message}`);
                    else console.log(`[undeploy] deleted ${filePath}`);
                });
            } else {
                console.warn(`[undeploy] UUID ${uuid} not found in registry`);
            }
            console.log(`[undeploy] done for ${uuid}`);
            ws.send(codec.encodeServer({ ack: {} }), { binary: true });
            ws.close();
        });
    });
}

server.on('request', (req, res) => {
    const uuid = req.url.slice(1);
    console.log(`[download] request: ${req.method} ${req.url}`);
    if (!/^[0-9a-f-]{36}$/.test(uuid)) {
        console.log(`[download] rejected — not a UUID: "${uuid}"`);
        res.writeHead(404); res.end('Not found'); return;
    }

    fs.readFile(REGISTRY_FILE, 'utf8', (err, data) => {
        if (err) {
            console.error(`[download] failed to read registry: ${err.message}`);
            res.writeHead(500); res.end('Registry unavailable'); return;
        }

        const entry = data.trim().split('\n')
            .map(line => { try { return JSON.parse(line); } catch (_) { return null; } })
            .find(e => e && e.uuid === uuid);

        if (!entry) {
            console.log(`[download] UUID not found in registry: ${uuid}`);
            res.writeHead(404); res.end('Not found'); return;
        }

        const filePath = path.join(BUILDS_DIR, entry.filename);
        console.log(`[download] resolved path: ${filePath}`);
        fs.stat(filePath, (statErr, stats) => {
            if (statErr) {
                console.error(`[download] file not found on disk: ${filePath} — ${statErr.message}`);
                res.writeHead(404); res.end('File not found'); return;
            }
            console.log(`[download] serving ${entry.filename} (${stats.size} bytes)`);
            res.writeHead(200, {
                'Content-Type': 'application/octet-stream',
                'Content-Disposition': `attachment; filename="${entry.filename}"`,
                'Content-Length': stats.size,
            });
            const stream = fs.createReadStream(filePath);
            stream.on('error', (err) => console.error(`[download] stream error: ${err.message}`));
            stream.on('end', () => console.log(`[download] done: ${entry.filename}`));
            stream.pipe(res);
        });
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
