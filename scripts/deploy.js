const https = require('https');

// Shared with tests/helpers/distClient.js so the integration tests exercise the exact
// same HTTPS upload request a real deploy issues, instead of a second reimplementation.
function uploadBuild({ host, port, token, filename, contents }) {
    return new Promise((resolve, reject) => {
        const req = https.request({
            hostname: host,
            port: parseInt(port, 10),
            path: '/upload',
            method: 'POST',
            rejectUnauthorized: false, // self-signed cert
            headers: {
                'Authorization': `Bearer ${token}`,
                'X-Filename': filename,
                'Content-Type': 'application/octet-stream',
                'Content-Length': contents.length,
            },
        }, (res) => {
            res.resume();
            if (res.statusCode === 200) resolve();
            else reject(new Error(`upload failed: HTTP ${res.statusCode}`));
        });
        req.on('error', reject);
        req.end(contents);
    });
}

module.exports = { uploadBuild };

// Everything below is the `node scripts/deploy.js <mac|win|linux>` CLI entry point.
// Guarded so tests/helpers/distClient.js can require() this file for `uploadBuild`
// without triggering platform-arg validation or a real electron-builder run.
if (require.main === module) {
    const crypto = require('crypto');
    const fs = require('fs');
    const path = require('path');
    const { spawn } = require('child_process');
    const Ws = require('ws');
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
    const codec = require('../server/codec.js');
    const auth = require('../server/auth.js');

    const PLATFORM = process.argv[2];
    if (PLATFORM !== 'mac' && PLATFORM !== 'win' && PLATFORM !== 'linux') {
        console.error('Usage: node scripts/deploy.js <mac|win|linux>');
        process.exit(1);
    }

    const host = process.env.PROD_SERVER_HOST;
    const port = process.env.PROD_SERVER_PORT || '443';
    const SERVER_URL = port === '443' ? `wss://${host}` : `wss://${host}:${port}`;
    const UUID_FILE = path.join(__dirname, '..', 'app-uuid.json');
    const WIN_SCREEN_FILE = path.join(__dirname, '..', 'config', 'win-screen.json');
    const DIST_DIR = path.join(__dirname, '..', 'dist');
    const EXTENSION = PLATFORM === 'mac' ? '.dmg' : PLATFORM === 'win' ? '.exe' : '.AppImage';

    const fail = (msg) => {
        console.error(`[dist] ${msg}`);
        process.exit(1);
    };

    // The win text lives only on the server (stored per-build in builds.jsonl), so it is
    // read here at deploy time and sent with distComplete rather than bundled into the
    // client. config/win-screen.json is excluded from the electron-builder files list.
    function readWinText() {
        let raw;
        try {
            raw = fs.readFileSync(WIN_SCREEN_FILE, 'utf8');
        } catch (err) {
            fail(`could not read ${WIN_SCREEN_FILE}: ${err.message}`);
        }
        let text;
        try {
            text = JSON.parse(raw).text;
        } catch (err) {
            fail(`could not parse ${WIN_SCREEN_FILE}: ${err.message}`);
        }
        if (typeof text !== 'string' || text === '') {
            fail(`${WIN_SCREEN_FILE} must contain a non-empty "text" string`);
        }
        return text;
    }

    function generateUuid() {
        const uuid = crypto.randomUUID();
        fs.writeFileSync(UUID_FILE, JSON.stringify({ uuid }, null, 2) + '\n');
        console.log(`[dist] generated uuid ${uuid}, wrote ${UUID_FILE}`);
        return uuid;
    }

    function connect() {
        return new Promise((resolve, reject) => {
            const ws = new Ws(SERVER_URL, { rejectUnauthorized: false });
            ws.once('open', () => resolve(ws));
            ws.once('error', (err) => reject(err));
        });
    }

    function send(ws, payload) {
        ws.send(codec.encodeClient(payload), { binary: true });
    }

    function runElectronBuilder() {
        return new Promise((resolve, reject) => {
            const args = [PLATFORM === 'mac' ? '--mac' : PLATFORM === 'win' ? '--win' : '--linux'];
            console.log(`[dist] running electron-builder ${args.join(' ')}`);
            const child = spawn('npx', ['electron-builder', ...args], {
                cwd: path.join(__dirname, '..'),
                stdio: 'inherit',
            });
            child.on('exit', (code) => {
                if (code === 0) resolve();
                else reject(new Error(`electron-builder exited with code ${code}`));
            });
            child.on('error', reject);
        });
    }

    function findBuiltFile() {
        const entries = fs.readdirSync(DIST_DIR)
            .filter((name) => name.toLowerCase().endsWith(EXTENSION.toLowerCase()))
            .map((name) => {
                const full = path.join(DIST_DIR, name);
                return { name, full, mtime: fs.statSync(full).mtimeMs };
            })
            .sort((a, b) => b.mtime - a.mtime);
        if (entries.length === 0) {
            throw new Error(`no ${EXTENSION} file found in ${DIST_DIR}`);
        }
        return entries[0];
    }

    async function main() {
        const uuid = generateUuid();

        let pendingMessageResolver = null;
        const incoming = [];

        const nextMessage = () => new Promise((resolve) => {
            if (incoming.length > 0) resolve(incoming.shift());
            else pendingMessageResolver = resolve;
        });

        // Push a decoded server message (or the synthetic _closed sentinel) into
        // the shared queue regardless of which WebSocket connection is current.
        function pushMessage(msg) {
            if (pendingMessageResolver) {
                const r = pendingMessageResolver;
                pendingMessageResolver = null;
                r(msg);
            } else {
                incoming.push(msg);
            }
        }

        // Attach message + close handlers to a socket so both feed the same queue.
        function wireSocket(socket) {
            socket.on('message', (data) => {
                let msg;
                try { msg = codec.decodeServer(data); }
                catch (err) { console.error('[dist] decode error:', err.message); return; }
                pushMessage(msg);
            });
            socket.on('close', () => pushMessage({ payload: '_closed' }));
        }

        let ws = await connect().catch((err) => fail(`could not connect to ${SERVER_URL}: ${err.message}`));
        console.log(`[dist] connected to ${SERVER_URL}`);
        wireSocket(ws);

        send(ws, { distRegister: { uuid, platform: PLATFORM } });
        console.log(`[dist] sent dist_register`);

        // Auth loop. If key auth fails the server closes the connection; the
        // _closed sentinel triggers a reconnect and password retry on the new socket.
        let pendingRetry = false;
        let uploadToken = null;
        while (true) {
            const msg = await nextMessage();
            if (msg.payload === '_closed') {
                if (!pendingRetry) fail('connection closed before auth completed');
                console.log('[dist] reconnecting for password authentication');
                ws = await connect().catch((err) => fail(`could not reconnect to ${SERVER_URL}: ${err.message}`));
                wireSocket(ws);
                pendingRetry = false;
                send(ws, { distRegister: { uuid, platform: PLATFORM } });
            } else if (msg.payload === 'authChallenge') {
                console.log('[dist] received auth_challenge, responding');
                const response = await auth.handleAuthChallenge(msg.authChallenge);
                send(ws, { authResponse: response });
            } else if (msg.payload === 'authResult') {
                auth.handleAuthResult(msg.authResult);
                const variant = msg.authResult.password || msg.authResult.key || {};
                const isKeyFailure = !!(msg.authResult.key && !msg.authResult.key.success);
                if (isKeyFailure) { pendingRetry = true; }
                else if (!variant.success) { fail('authentication failed'); }
            } else if (msg.payload === 'distRegisterAck') {
                uploadToken = msg.distRegisterAck.uploadToken;
                break;
            }
        }
        if (!uploadToken) fail('server did not issue an upload token');

        // Read (and validate) the win text before the slow electron-builder run so a
        // missing/malformed config fails fast rather than after a full build.
        const winText = readWinText();

        console.log('[dist] auth complete; running electron-builder');
        await runElectronBuilder().catch((err) => fail(err.message));

        const built = findBuiltFile();
        console.log(`[dist] found built file ${built.name} (${built.mtime})`);
        const contents = fs.readFileSync(built.full);
        console.log(`[dist] uploading ${contents.length} bytes via HTTPS`);

        await uploadBuild({ host, port, token: uploadToken, filename: built.name, contents });
        console.log('[dist] upload complete');

        send(ws, { distComplete: { uuid, filename: built.name, winText } });

        while (true) {
            const msg = await nextMessage();
            if (msg.payload === '_closed') fail('connection closed before upload acknowledged');
            if (msg.payload === 'distCompleteAck') break;
        }

        console.log('[dist] upload acknowledged, done');
        ws.close();
        process.exit(0);
    }

    main().catch((err) => fail(err.stack || err.message));
}
