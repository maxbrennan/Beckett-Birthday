const path = require('path');
const { computeServerUrl, createMessageQueue, wireSocket, classifyAuthResult, formatBuildListLine } = require('./lib/wsClient.js');

function validateEditedJson(text) {
    try {
        JSON.parse(text);
        return { ok: true };
    } catch (e) {
        return { ok: false, error: e.message };
    }
}

module.exports = { validateEditedJson };

if (require.main === module) {
    const Ws = require('ws');
    const fs = require('fs');
    const os = require('os');
    const { spawnSync } = require('child_process');
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
    const codec = require('../server/codec.js');
    const auth = require('../server/auth.js');

    const uuid = process.argv[2];
    const SERVER_URL = computeServerUrl(process.env);
    const fail = (msg) => { console.error(`[edit-state] ${msg}`); process.exit(1); };

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
        const wire = (socket) => wireSocket(socket, { codec, pushMessage, tag: 'edit-state' });

        let ws = await connect().catch((err) => fail(`could not connect to ${SERVER_URL}: ${err.message}`));
        console.log(`[edit-state] connected to ${SERVER_URL}`);
        wire(ws);

        if (!uuid) {
            console.log('[edit-state] no UUID provided — fetching list of player UUIDs');
            send(ws, { distList: {} });

            let pendingRetry = false;
            while (true) {
                const msg = await nextMessage();
                if (msg.payload === '_closed') {
                    if (!pendingRetry) fail('connection closed before auth completed');
                    console.log('[edit-state] reconnecting for password authentication');
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
                        console.log('[edit-state] no builds deployed');
                    } else {
                        console.log('\nDeployed builds:');
                        for (const e of entries) {
                            console.log(formatBuildListLine(e));
                        }
                        console.log(`\nRun: npm run edit:state <uuid>`);
                    }
                    process.exit(0);
                }
            }
        } else {
            console.log(`[edit-state] requesting edit of state for ${uuid}`);
            send(ws, { distStateEdit: { uuid } });

            let pendingRetry = false;
            while (true) {
                const msg = await nextMessage();
                if (msg.payload === '_closed') {
                    if (!pendingRetry) fail('connection closed before auth completed');
                    console.log('[edit-state] reconnecting for password authentication');
                    ws = await connect().catch((err) => fail(`could not reconnect to ${SERVER_URL}: ${err.message}`));
                    wire(ws);
                    pendingRetry = false;
                    send(ws, { distStateEdit: { uuid } });
                } else if (msg.payload === 'authChallenge') {
                    const response = await auth.handleAuthChallenge(msg.authChallenge);
                    send(ws, { authResponse: response });
                } else if (msg.payload === 'authResult') {
                    auth.handleAuthResult(msg.authResult);
                    const { success, isKeyFailure } = classifyAuthResult(msg.authResult);
                    if (isKeyFailure) { pendingRetry = true; }
                    else if (!success) { fail('authentication failed'); }
                    else { console.log('[edit-state] authenticated'); }
                } else if (msg.payload === 'distStateEditPayload') {
                    const { json } = msg.distStateEditPayload;
                    const tmpFile = path.join(os.tmpdir(), `state-edit-${uuid}.json`);
                    fs.writeFileSync(tmpFile, JSON.stringify(JSON.parse(json), null, 2));

                    const editor = process.env.EDITOR || 'vi';
                    console.log(`[edit-state] opening ${editor} — save and quit when done`);
                    const result = spawnSync(editor, [tmpFile], { stdio: 'inherit' });
                    if (result.error) fail(`editor failed: ${result.error.message}`);

                    const edited = fs.readFileSync(tmpFile, 'utf8');
                    const validation = validateEditedJson(edited);
                    if (!validation.ok) fail(`invalid JSON after editing: ${validation.error}`);
                    try { fs.unlinkSync(tmpFile); } catch (_) {}

                    console.log('[edit-state] saving state...');
                    send(ws, { distStateEditSave: { uuid, json: edited } });
                } else if (msg.payload === 'ack') {
                    console.log('[edit-state] done');
                    ws.close();
                    break;
                } else if (msg.payload === 'stateRequestRejected') {
                    fail(`rejected: ${msg.stateRequestRejected.reason}`);
                }
            }
        }
    }

    main().catch((err) => fail(err.stack || err.message));
}
