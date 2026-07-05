const crypto = require('crypto');
const WebSocket = require('ws');
const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const { Elm } = require('../elm-server.js');
const codec = require('./codec.js');
const auth = require('./auth.js');

const isDev = process.env.DEV === 'true';
const PORT = parseInt(isDev ? process.env.DEV_SERVER_PORT : process.env.PROD_SERVER_PORT, 10) || (isDev ? 8443 : 443);

const CERT_FILE = path.join(__dirname, '..', process.env.SSL_CERT_FILE || path.join('certs', 'cert.pem'));
const KEY_FILE = path.join(__dirname, '..', process.env.SSL_KEY_FILE || path.join('certs', 'key.pem'));

const app = Elm.Server.init();
const clients = new Map();
// Tracks the outstanding auth challenge per client (populated by the requestAuth
// port). All admin-op routing that used to live here now lives in the Elm worker.
const pendingAuths = new Map();
// Upload tokens minted for the HTTP POST /upload handler (crypto stays in JS).
const validUploadTokens = new Set();
let nextId = 0;

const server = https.createServer({
    cert: fs.readFileSync(CERT_FILE),
    key: fs.readFileSync(KEY_FILE),
});
// Reload TLS credentials in-place when cert or key files change (e.g. Let's
// Encrypt renewal). Debounced so a simultaneous cert+key write only triggers once.
let certReloadTimer = null;
function reloadCerts() {
    try {
        server.setSecureContext({ cert: fs.readFileSync(CERT_FILE), key: fs.readFileSync(KEY_FILE) });
        console.log('[cert] reloaded TLS certificates');
    } catch (err) {
        console.error(`[cert] failed to reload certificates: ${err.message}`);
    }
}
fs.watch(CERT_FILE, () => { clearTimeout(certReloadTimer); certReloadTimer = setTimeout(reloadCerts, 500); });
fs.watch(KEY_FILE,  () => { clearTimeout(certReloadTimer); certReloadTimer = setTimeout(reloadCerts, 500); });

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
            // The Elm worker owns all post-auth routing (undeploy / list / state-edit /
            // register): it decided to requestAuth, and it acts on the outcome here.
            app.ports.authResult.send({
                clientId,
                success: !!variant.success,
                level: variant.level || 0,
                uuid: variant.uuid || '',
            });
            return;
        }

        // Every other message (including distUndeploy / distList / distStateEdit /
        // distStateEditSave / distRegister) forwards straight to the Elm worker, which
        // gates admin ops behind the requestAuth/authResult ports.
        app.ports.onMessage.send({ clientId, payload: msg });
    });

    ws.on('close', () => {
        clients.delete(clientId);
        pendingAuths.delete(clientId);
        // Elm's ClientDisconnected handler clears any distClients stage for this client.
        app.ports.onDisconnection.send(clientId);
    });
});

app.ports.sendToClient.subscribe(({ clientId, payload }) => {
    const ws = clients.get(clientId);
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    let serverPayload = payload;
    // Elm requests an upload token via a marker inside the ack (crypto stays in JS).
    // The marker is rewritten to a real token here and never reaches the codec.
    if (payload.ack && payload.ack.mintUploadToken) {
        const token = crypto.randomBytes(32).toString('hex');
        validUploadTokens.add(token);
        serverPayload = { ack: { uploadToken: token } };
    }
    ws.send(codec.encodeServer(serverPayload), { binary: true });
});

app.ports.stateEditReady.subscribe(({ adminClientId, uuid, json }) => {
    const ws = clients.get(adminClientId);
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(codec.encodeServer({ distStateEditPayload: { uuid, json } }), { binary: true });
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

// Combines a send + close into one port so the two always happen in the same JS event
// loop tick, in this order — Elm's Cmd.batch does not guarantee that two separate ports
// (e.g. sendToClient then closeClient) dispatch to JS in list order, which previously
// meant the reject message could be dropped if closeClient's subscriber ran first.
app.ports.rejectAndClose.subscribe(({ clientId, reason, payload }) => {
    const ws = clients.get(clientId);
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(codec.encodeServer(payload), { binary: true });
        try {
            ws.close(1000, reason);
        } catch (_) {}
    }
    clients.delete(clientId);
});

app.ports.readFile.subscribe((filePath) => {
    const fullPath = path.isAbsolute(filePath) ? filePath : path.join(process.cwd(), filePath);
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
    const fullPath = path.isAbsolute(filePath) ? filePath : path.join(process.cwd(), filePath);
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

const REGISTRY_FILE = path.join(process.cwd(), 'app-builds', 'builds.jsonl');
const BUILDS_DIR = path.join(process.cwd(), 'app-builds');

app.ports.deleteBuildFile.subscribe((filename) => {
    const filePath = path.join(BUILDS_DIR, filename);
    fs.unlink(filePath, (err) => {
        if (err) console.error(`[undeploy] failed to delete file: ${err.message}`);
        else console.log(`[undeploy] deleted ${filePath}`);
    });
});

server.on('request', (req, res) => {
    if (req.method === 'POST' && req.url === '/upload') {
        const authHeader = req.headers['authorization'] || '';
        const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
        if (!validUploadTokens.has(token)) {
            console.error('[upload] invalid or missing upload token');
            res.writeHead(401); res.end('Unauthorized'); return;
        }
        validUploadTokens.delete(token);

        const filename = req.headers['x-filename'] || '';
        if (!filename || filename.includes('..') || filename.includes('/')) {
            console.error(`[upload] bad filename: "${filename}"`);
            res.writeHead(400); res.end('Bad filename'); return;
        }

        console.log(`[upload] receiving ${filename}`);
        fs.mkdir(BUILDS_DIR, { recursive: true }, () => {
            const filePath = path.join(BUILDS_DIR, filename);
            const out = fs.createWriteStream(filePath);
            req.pipe(out);
            out.on('finish', () => {
                console.log(`[upload] saved ${filename}`);
                res.writeHead(200); res.end('OK');
            });
            out.on('error', (err) => {
                console.error(`[upload] write error: ${err.message}`);
                res.writeHead(500); res.end('Write error');
            });
            req.on('error', () => out.destroy());
        });
        return;
    }

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

        if (entry.pendingStateEdit) {
            console.log(`[download] rejected — pending state edit: ${uuid}`);
            res.writeHead(423); res.end('Locked'); return;
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

server.listen(PORT, '0.0.0.0', () => {
    console.log(`WebSocket server listening on port ${PORT}`);
});

const shutdown = () => { wss.close(() => server.close(() => process.exit(0))); };
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.on('SIGHUP', () => {});
