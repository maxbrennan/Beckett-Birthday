const path = require('path');
const { computeServerUrl, createMessageQueue, wireSocket, classifyAuthResult, formatBuildListLine } = require('./lib/wsClient.js');

if (require.main === module) {
    const Ws = require('ws');
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
    const codec = require('../server/codec.js');
    const auth = require('../server/auth.js');

    const uuid = process.argv[2];
    const SERVER_URL = computeServerUrl(process.env);
    const fail = (msg) => { console.error(`[undeploy] ${msg}`); process.exit(1); };

    function connect() {
        return new Promise((resolve, reject) => {
            const sock = new Ws(SERVER_URL, { rejectUnauthorized: false });
            sock.once('open', () => resolve(sock));
            sock.once('error', reject);
        });
    }

    function send(ws, payload) {
        ws.send(codec.encodeClient(payload), { binary: true });
    }

    async function main() {
        const { nextMessage, pushMessage } = createMessageQueue();
        const wire = (socket) => wireSocket(socket, { codec, pushMessage, tag: 'undeploy' });

        let ws = await connect().catch((err) => fail(`could not connect to ${SERVER_URL}: ${err.message}`));
        console.log(`[undeploy] connected to ${SERVER_URL}`);
        wire(ws);

        if (!uuid) {
            // List mode: authenticate then display available builds
            console.log('[undeploy] no UUID provided — fetching list of deployed builds');
            send(ws, { distList: {} });

            let pendingRetry = false;
            while (true) {
                const msg = await nextMessage();
                if (msg.payload === '_closed') {
                    if (!pendingRetry) fail('connection closed before auth completed');
                    console.log('[undeploy] reconnecting for password authentication');
                    ws = await connect().catch((err) => fail(`could not reconnect to ${SERVER_URL}: ${err.message}`));
                    wire(ws);
                    pendingRetry = false;
                    send(ws, { distList: {} });
                } else if (msg.payload === 'authChallenge') {
                    const response = await auth.handleAuthChallenge(msg.authChallenge);
                    send(ws, { authResponse: response });
                } else if (msg.payload === 'authResult') {
                    auth.handleAuthResult(msg.authResult);
                    const { success, isKeyFailure } = classifyAuthResult(msg.authResult);
                    if (isKeyFailure) { pendingRetry = true; }
                    else if (!success) { fail('authentication failed'); }
                } else if (msg.payload === 'distListResult') {
                    const entries = msg.distListResult.entries || [];
                    if (entries.length === 0) {
                        console.log('[undeploy] no builds deployed');
                    } else {
                        console.log('\nDeployed builds:');
                        for (const e of entries) {
                            console.log(formatBuildListLine(e));
                        }
                        console.log(`\nRun: node scripts/undeploy.js <uuid>`);
                    }
                    process.exit(0);
                }
            }
        } else {
            // Undeploy mode
            console.log(`[undeploy] sent undeploy request for ${uuid}`);
            send(ws, { distUndeploy: { uuid } });

            let pendingRetry = false;
            while (true) {
                const msg = await nextMessage();
                if (msg.payload === '_closed') {
                    if (!pendingRetry) fail('connection closed before auth completed');
                    console.log('[undeploy] reconnecting for password authentication');
                    ws = await connect().catch((err) => fail(`could not reconnect to ${SERVER_URL}: ${err.message}`));
                    wire(ws);
                    pendingRetry = false;
                    send(ws, { distUndeploy: { uuid } });
                } else if (msg.payload === 'authChallenge') {
                    const response = await auth.handleAuthChallenge(msg.authChallenge);
                    send(ws, { authResponse: response });
                } else if (msg.payload === 'authResult') {
                    auth.handleAuthResult(msg.authResult);
                    const { success, isKeyFailure } = classifyAuthResult(msg.authResult);
                    if (isKeyFailure) { pendingRetry = true; }
                    else if (!success) { fail('authentication failed'); }
                    else { console.log('[undeploy] authenticated'); }
                } else if (msg.payload === 'distUndeployAck') {
                    console.log('[undeploy] done');
                    ws.close();
                    break;
                }
            }
        }
    }

    main().catch((err) => fail(err.stack || err.message));
}
