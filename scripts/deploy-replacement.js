const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const Ws = require('ws');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const codec = require('../server/codec.js');
const auth = require('../server/auth.js');

const PLATFORM = process.argv[2];
// OLD_UUID is optional: when omitted, we list the deployed builds and exit rather
// than error, so the admin can find the uuid they meant (see fetchBuildList/main).
// Platform validation is deferred to the require.main CLI guard so this module can be
// require()d by tests (for resolveReplacement) without exiting.
const OLD_UUID = process.argv[3];

const host = process.env.PROD_SERVER_HOST;
const port = process.env.PROD_SERVER_PORT || '443';
const SERVER_URL = port === '443' ? `wss://${host}` : `wss://${host}:${port}`;
const UUID_FILE = path.join(__dirname, '..', 'app-uuid.json');
const DIST_DIR = path.join(__dirname, '..', 'dist');
const EXTENSION = PLATFORM === 'mac' ? '.dmg' : '.exe';

const fail = (msg) => {
    console.error(`[dist] ${msg}`);
    process.exit(1);
};

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

// Pure decision over a distList-shaped `entries` array ([{ uuid, filename, platform }]):
//   - falsy oldUuid            -> 'list'    (no uuid given: show the deployed builds)
//   - oldUuid not in entries   -> 'abort'   (nonexistent uuid: refuse before building)
//   - oldUuid matches an entry -> 'proceed' (run the real build/upload/replace flow)
// Exported for tests; keep it side-effect free.
function resolveReplacement(entries, oldUuid) {
    if (!oldUuid) return { action: 'list' };
    const exists = (entries || []).some((e) => e.uuid === oldUuid);
    return exists ? { action: 'proceed' } : { action: 'abort' };
}

function printBuilds(entries) {
    if (!entries || entries.length === 0) {
        console.log('[dist] no builds deployed');
        return;
    }
    console.log('\nDeployed builds:');
    for (const e of entries) {
        console.log(`  ${e.uuid}  ${e.filename}  (${e.platform})`);
    }
    console.log(`\nRun: npm run deploy:replacement:${PLATFORM} -- <uuid>`);
}

// Admin-authenticated distList fetch, returning the entries array. Mirrors the
// auth/reconnect dance in scripts/undeploy.js (key-auth first; on key failure the
// server closes the socket, so we reconnect and retry with password auth), but
// resolves the entries instead of printing and exiting.
function fetchBuildList() {
    return new Promise((resolve) => {
        let pendingResolver = null;
        const incoming = [];
        const nextMessage = () => new Promise((r) => {
            if (incoming.length > 0) r(incoming.shift());
            else pendingResolver = r;
        });
        function pushMessage(msg) {
            if (pendingResolver) { const r = pendingResolver; pendingResolver = null; r(msg); }
            else incoming.push(msg);
        }
        function wireSocket(socket) {
            socket.on('message', (data) => {
                let msg;
                try { msg = codec.decodeServer(data); }
                catch (err) { console.error('[dist] decode error:', err.message); return; }
                pushMessage(msg);
            });
            socket.on('close', () => pushMessage({ payload: '_closed' }));
        }

        (async () => {
            let ws = await connect().catch((err) => fail(`could not connect to ${SERVER_URL}: ${err.message}`));
            wireSocket(ws);
            send(ws, { distList: {} });

            let pendingRetry = false;
            while (true) {
                const msg = await nextMessage();
                if (msg.payload === '_closed') {
                    if (!pendingRetry) fail('connection closed before auth completed');
                    console.log('[dist] reconnecting for password authentication');
                    ws = await connect().catch((err) => fail(`could not reconnect to ${SERVER_URL}: ${err.message}`));
                    wireSocket(ws);
                    pendingRetry = false;
                    send(ws, { distList: {} });
                } else if (msg.payload === 'authChallenge') {
                    const response = await auth.handleAuthChallenge(msg.authChallenge);
                    send(ws, { authResponse: response });
                } else if (msg.payload === 'authResult') {
                    auth.handleAuthResult(msg.authResult);
                    const variant = msg.authResult.password || msg.authResult.key || {};
                    const isKeyFailure = !!(msg.authResult.key && !msg.authResult.key.success);
                    if (isKeyFailure) { pendingRetry = true; }
                    else if (!variant.success) { fail('authentication failed'); }
                } else if (msg.payload === 'distListResult') {
                    const entries = msg.distListResult.entries || [];
                    // The server closes the socket right after sending distListResult; we
                    // have what we need, so resolve (a trailing _closed is harmless).
                    resolve(entries);
                    return;
                }
            }
        })();
    });
}

function runElectronBuilder() {
    return new Promise((resolve, reject) => {
        const args = [PLATFORM === 'mac' ? '--mac' : '--win'];
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
        .filter((name) => name.toLowerCase().endsWith(EXTENSION))
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
    // List-first validation: fetch the deployed builds and decide what to do before
    // generating a uuid or running electron-builder, so a missing/nonexistent oldUuid
    // never wastes a build.
    const entries = await fetchBuildList();
    const decision = resolveReplacement(entries, OLD_UUID);
    if (decision.action === 'list') {
        console.log('[dist] no uuid provided — listing deployed builds');
        printBuilds(entries);
        process.exit(0);
    }
    if (decision.action === 'abort') {
        console.error(`[dist] uuid ${OLD_UUID} not found — cannot deploy a replacement for it`);
        printBuilds(entries);
        process.exit(1);
    }

    const newUuid = generateUuid();

    let pendingMessageResolver = null;
    const incoming = [];

    const nextMessage = () => new Promise((resolve) => {
        if (incoming.length > 0) resolve(incoming.shift());
        else pendingMessageResolver = resolve;
    });

    function pushMessage(msg) {
        if (pendingMessageResolver) {
            const r = pendingMessageResolver;
            pendingMessageResolver = null;
            r(msg);
        } else {
            incoming.push(msg);
        }
    }

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

    send(ws, { distRegister: { uuid: newUuid, platform: PLATFORM } });
    console.log(`[dist] sent dist_register`);

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
            send(ws, { distRegister: { uuid: newUuid, platform: PLATFORM } });
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
        } else if (msg.payload === 'ack') {
            uploadToken = msg.ack.uploadToken;
            break;
        }
    }
    if (!uploadToken) fail('server did not issue an upload token');

    console.log('[dist] auth complete; running electron-builder');
    await runElectronBuilder().catch((err) => fail(err.message));

    const built = findBuiltFile();
    console.log(`[dist] found built file ${built.name} (${built.mtime})`);
    const contents = fs.readFileSync(built.full);
    console.log(`[dist] uploading ${contents.length} bytes via HTTPS`);

    await new Promise((resolve, reject) => {
        const req = https.request({
            hostname: host,
            port: parseInt(port, 10),
            path: '/upload',
            method: 'POST',
            rejectUnauthorized: false,
            headers: {
                'Authorization': `Bearer ${uploadToken}`,
                'X-Filename': built.name,
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
    console.log('[dist] upload complete');

    send(ws, { distReplaceComplete: { newUuid, oldUuid: OLD_UUID, filename: built.name } });

    while (true) {
        const msg = await nextMessage();
        if (msg.payload === '_closed') fail('connection closed before replacement acknowledged');
        if (msg.payload === 'ack') break;
    }

    console.log(`[dist] replacement acknowledged — old uuid ${OLD_UUID} replaced by ${newUuid}`);
    ws.close();

    console.log(`[dist] launching edit:state for ${newUuid}`);
    const result = spawnSync('node', [path.join(__dirname, 'edit-state.js'), newUuid], {
        stdio: 'inherit',
        cwd: path.join(__dirname, '..'),
    });
    if (result.error) fail(`edit-state failed: ${result.error.message}`);
    process.exit(result.status || 0);
}

// Exported for tests (tests/deploy-replacement.test.js) before the CLI guard so a
// require() gets the pure decision helper without running the deploy flow.
module.exports = { resolveReplacement };

if (require.main === module) {
    if (PLATFORM !== 'mac' && PLATFORM !== 'win') {
        console.error('Usage: node scripts/deploy-replacement.js <mac|win> [old-uuid]');
        process.exit(1);
    }
    main().catch((err) => fail(err.stack || err.message));
}
