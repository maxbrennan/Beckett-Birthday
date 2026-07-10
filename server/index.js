const path = require('path');

function resolveCertPaths(env, rootDir) {
    const certFile = path.join(rootDir, env.SSL_CERT_FILE || path.join('certs', 'cert.pem'));
    const keyFile = path.join(rootDir, env.SSL_KEY_FILE || path.join('certs', 'key.pem'));
    return { certFile, keyFile };
}

// Shape-validates the /upload request (bearer token presence, safe filename); token
// membership against validUploadTokens is checked by the caller since that's stateful.
function parseUploadRequest(req) {
    const authHeader = req.headers['authorization'] || '';
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
    const filename = req.headers['x-filename'] || '';
    const filenameValid = !!filename && !filename.includes('..') && !filename.includes('/');
    return { token, filename, filenameValid };
}

function isValidUuid(uuid) {
    return /^[0-9a-f-]{36}$/.test(uuid);
}

function findRegistryEntry(registryText, uuid) {
    return registryText.trim().split('\n')
        .map(line => { try { return JSON.parse(line); } catch (_) { return null; } })
        .find(e => e && e.uuid === uuid) || null;
}

function resolveDownloadDecision(entry) {
    if (!entry) return { type: 'not-found' };
    if (entry.pendingStateEdit) return { type: 'locked' };
    return { type: 'ok', filename: entry.filename };
}

// Elm requests an upload token via a marker inside the distRegisterAck (crypto stays in JS).
// mintToken is injected so tests don't need real crypto.randomBytes.
function buildSendToClientPayload(payload, mintToken) {
    if (payload.distRegisterAck && payload.distRegisterAck.mintUploadToken) {
        const token = mintToken();
        return { serverPayload: { distRegisterAck: { uploadToken: token } }, token };
    }
    return { serverPayload: payload, token: null };
}

module.exports = {
    resolveCertPaths,
    parseUploadRequest,
    isValidUuid,
    findRegistryEntry,
    resolveDownloadDecision,
    buildSendToClientPayload,
};

// Only run the live server (and pull in ../elm-server.js, a build artifact) when this
// file is invoked as `node server/index.js` — that keeps requiring it for the exported
// pure functions above free of the build step, in CI's js-unit job as much as in Jest.
if (require.main === module) {
    const crypto = require('crypto');
    const WebSocket = require('ws');
    const https = require('https');
    const fs = require('fs');
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
    const { Elm } = require('../elm-server.js');
    const codec = require('./codec.js');
    const auth = require('./auth.js');

    const isDev = process.env.DEV === 'true';
    const PORT = parseInt(isDev ? process.env.DEV_SERVER_PORT : process.env.PROD_SERVER_PORT, 10) || (isDev ? 8443 : 443);

    const { certFile: CERT_FILE, keyFile: KEY_FILE } = resolveCertPaths(process.env, path.join(__dirname, '..'));

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
            // gates admin ops behind the requestAuth/authResult ports. `now` gives the Elm
            // worker (a Platform.worker with no wall clock of its own otherwise) its own
            // server-side timestamp for e.g. the 7-day session-timer deadline, rather than
            // trusting anything the client itself reports.
            app.ports.onMessage.send({ clientId, payload: msg, now: Date.now() });
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
        const { serverPayload, token } = buildSendToClientPayload(payload, () => crypto.randomBytes(32).toString('hex'));
        if (token) validUploadTokens.add(token);
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
            const { token, filename, filenameValid } = parseUploadRequest(req);
            if (!validUploadTokens.has(token)) {
                console.error('[upload] invalid or missing upload token');
                res.writeHead(401); res.end('Unauthorized'); return;
            }
            validUploadTokens.delete(token);

            if (!filenameValid) {
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
        if (!isValidUuid(uuid)) {
            console.log(`[download] rejected — not a UUID: "${uuid}"`);
            res.writeHead(404); res.end('Not found'); return;
        }

        fs.readFile(REGISTRY_FILE, 'utf8', (err, data) => {
            if (err) {
                console.error(`[download] failed to read registry: ${err.message}`);
                res.writeHead(500); res.end('Registry unavailable'); return;
            }

            const entry = findRegistryEntry(data, uuid);
            const decision = resolveDownloadDecision(entry);

            if (decision.type === 'not-found') {
                console.log(`[download] UUID not found in registry: ${uuid}`);
                res.writeHead(404); res.end('Not found'); return;
            }

            if (decision.type === 'locked') {
                console.log(`[download] rejected — pending state edit: ${uuid}`);
                res.writeHead(423); res.end('Locked'); return;
            }

            const filePath = path.join(BUILDS_DIR, decision.filename);
            console.log(`[download] resolved path: ${filePath}`);
            fs.stat(filePath, (statErr, stats) => {
                if (statErr) {
                    console.error(`[download] file not found on disk: ${filePath} — ${statErr.message}`);
                    res.writeHead(404); res.end('File not found'); return;
                }
                console.log(`[download] serving ${decision.filename} (${stats.size} bytes)`);
                res.writeHead(200, {
                    'Content-Type': 'application/octet-stream',
                    'Content-Disposition': `attachment; filename="${decision.filename}"`,
                    'Content-Length': stats.size,
                });
                const stream = fs.createReadStream(filePath);
                stream.on('error', (err) => console.error(`[download] stream error: ${err.message}`));
                stream.on('end', () => console.log(`[download] done: ${decision.filename}`));
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
}
