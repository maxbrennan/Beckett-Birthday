const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const Ws = require('ws');
const codec = require('../server/codec.js');
const auth = require('../server/auth.js');

const PLATFORM = process.argv[2];
if (PLATFORM !== 'mac' && PLATFORM !== 'win') {
    console.error('Usage: node scripts/deploy.js <mac|win>');
    process.exit(1);
}

const SERVER_URL = process.env.DIST_SERVER_URL || 'wss://localhost';
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
    const uuid = generateUuid();

    const ws = await connect().catch((err) => fail(`could not connect to ${SERVER_URL}: ${err.message}`));
    console.log(`[dist] connected to ${SERVER_URL}`);

    const acks = [];
    let pendingMessageResolver = null;
    const incoming = [];

    const nextMessage = () => new Promise((resolve) => {
        if (incoming.length > 0) resolve(incoming.shift());
        else pendingMessageResolver = resolve;
    });

    ws.on('message', (data) => {
        let msg;
        try { msg = codec.decodeServer(data); }
        catch (err) { console.error('[dist] decode error:', err.message); return; }
        if (pendingMessageResolver) {
            const r = pendingMessageResolver;
            pendingMessageResolver = null;
            r(msg);
        } else {
            incoming.push(msg);
        }
    });

    ws.on('close', () => {
        if (acks.length < 2) fail('connection closed before flow completed');
    });

    send(ws, { distRegister: { uuid, platform: PLATFORM } });
    console.log(`[dist] sent dist_register`);

    while (true) {
        const msg = await nextMessage();
        if (msg.payload === 'authChallenge') {
            console.log('[dist] received auth_challenge, responding');
            const response = await auth.handleAuthChallenge(msg.authChallenge);
            send(ws, { authResponse: response });
        } else if (msg.payload === 'authResult') {
            auth.handleAuthResult(msg.authResult);
            const variant = msg.authResult.password || msg.authResult.key || {};
            if (!variant.success) fail('authentication failed');
        } else if (msg.payload === 'ack') {
            acks.push(true);
            break;
        } else {
            // ignore stateUpdate etc.
        }
    }

    console.log('[dist] auth complete; running electron-builder');
    await runElectronBuilder().catch((err) => fail(err.message));

    const built = findBuiltFile();
    console.log(`[dist] found built file ${built.name} (${built.mtime})`);
    const contents = fs.readFileSync(built.full);

    const CHUNK_SIZE = 1024 * 1024; // 1 MB
    const totalChunks = Math.max(1, Math.ceil(contents.length / CHUNK_SIZE));
    console.log(`[dist] uploading ${contents.length} bytes in ${totalChunks} chunk(s)`);

    for (let i = 0; i < totalChunks; i++) {
        const start = i * CHUNK_SIZE;
        const end = Math.min(start + CHUNK_SIZE, contents.length);
        const chunk = contents.subarray(start, end);
        const isLast = i === totalChunks - 1;
        await new Promise((resolve, reject) => {
            ws.send(
                codec.encodeClient({
                    distUpload: {
                        uuid,
                        filename: built.name,
                        contents: chunk,
                        chunkIndex: i,
                        isLast,
                    },
                }),
                { binary: true },
                (err) => (err ? reject(err) : resolve()),
            );
        });
        // Respect backpressure: drain if the socket has buffered too much.
        while (ws.bufferedAmount > 8 * CHUNK_SIZE) {
            await new Promise((r) => setTimeout(r, 25));
        }
    }
    console.log('[dist] all chunks sent');

    while (true) {
        const msg = await nextMessage();
        if (msg.payload === 'ack') {
            acks.push(true);
            break;
        }
    }

    console.log('[dist] upload acknowledged, done');
    ws.close();
    process.exit(0);
}

main().catch((err) => fail(err.stack || err.message));
