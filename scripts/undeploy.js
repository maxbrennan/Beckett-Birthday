const Ws = require('ws');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const codec = require('../server/codec.js');
const auth = require('../server/auth.js');

const uuid = process.argv[2];

const host = process.env.PROD_SERVER_HOST;
const port = process.env.PROD_SERVER_PORT || '443';
const SERVER_URL = port === '443' ? `wss://${host}` : `wss://${host}:${port}`;
const fail = (msg) => { console.error(`[undeploy] ${msg}`); process.exit(1); };

function send(ws, payload) {
    ws.send(codec.encodeClient(payload), { binary: true });
}

async function main() {
    const ws = await new Promise((resolve, reject) => {
        const sock = new Ws(SERVER_URL, { rejectUnauthorized: false });
        sock.once('open', () => resolve(sock));
        sock.once('error', reject);
    }).catch((err) => fail(`could not connect to ${SERVER_URL}: ${err.message}`));

    console.log(`[undeploy] connected to ${SERVER_URL}`);

    let pendingResolver = null;
    const incoming = [];
    const nextMessage = () => new Promise((resolve) => {
        if (incoming.length > 0) resolve(incoming.shift());
        else pendingResolver = resolve;
    });

    ws.on('message', (data) => {
        let msg;
        try { msg = codec.decodeServer(data); } catch (err) { console.error('[undeploy] decode error:', err.message); return; }
        if (pendingResolver) { const r = pendingResolver; pendingResolver = null; r(msg); }
        else incoming.push(msg);
    });

    ws.on('close', () => process.exit(0));

    if (!uuid) {
        // List mode: authenticate then display available builds
        send(ws, { distList: {} });
        console.log('[undeploy] no UUID provided — fetching list of deployed builds');

        while (true) {
            const msg = await nextMessage();
            if (msg.payload === 'authChallenge') {
                const response = await auth.handleAuthChallenge(msg.authChallenge);
                send(ws, { authResponse: response });
            } else if (msg.payload === 'authResult') {
                const { needsRetry } = auth.handleAuthResult(msg.authResult);
                const variant = msg.authResult.password || msg.authResult.key || {};
                if (!variant.success && !needsRetry) fail('authentication failed');
            } else if (msg.payload === 'distListResult') {
                const entries = msg.distListResult.entries || [];
                if (entries.length === 0) {
                    console.log('[undeploy] no builds deployed');
                } else {
                    console.log('\nDeployed builds:');
                    for (const e of entries) {
                        console.log(`  ${e.uuid}  ${e.filename}  (${e.platform})`);
                    }
                    console.log(`\nRun: node scripts/undeploy.js <uuid>`);
                }
                process.exit(0);
            }
        }
    } else {
        // Undeploy mode
        send(ws, { distUndeploy: { uuid } });
        console.log(`[undeploy] sent undeploy request for ${uuid}`);

        while (true) {
            const msg = await nextMessage();
            if (msg.payload === 'authChallenge') {
                console.log('[undeploy] received auth challenge, responding');
                const response = await auth.handleAuthChallenge(msg.authChallenge);
                send(ws, { authResponse: response });
            } else if (msg.payload === 'authResult') {
                const { needsRetry } = auth.handleAuthResult(msg.authResult);
                const variant = msg.authResult.password || msg.authResult.key || {};
                if (!variant.success && !needsRetry) fail('authentication failed');
                console.log('[undeploy] authenticated');
            } else if (msg.payload === 'ack') {
                console.log('[undeploy] done');
                ws.close();
                break;
            }
        }
    }
}

main().catch((err) => fail(err.stack || err.message));
