'use strict';

const fs = require('fs');
const path = require('path');
const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { waitUntil } = require('./helpers/waitUntil');

const TEST_PORT = 19449;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;
let build;

function readRegistry() {
    const file = path.join(server.tempDir, 'app-builds', 'builds.jsonl');
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

// One deployed build (registry entry starts with state: null) is shared across this
// file's non-destructive tests; the invalid-JSON case (last) uses its own separate
// build, since it leaves that uuid stuck in the server's pendingStateEdits set
// indefinitely (a discovered quirk in src/Server.elm's ClientDistStateEditSave, out of
// scope to fix here) — nothing after it needs that uuid again.
describe('edit state', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
        admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-3.0.0-universal.dmg',
        });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('lists the current uuid without acting', async () => {
        const { authResult, entries } = await distClient.listBuilds(TEST_PORT, admin);
        expect(authResult.success).toBe(true);
        expect(entries.some((e) => e.uuid === build.uuid)).toBe(true);

        const entry = readRegistry().find((e) => e.uuid === build.uuid);
        expect(entry.state).toBeFalsy();
    });

    test('successfully edits the state when a uuid is provided', async () => {
        const { authResult, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        expect(JSON.parse(json)).toEqual({}); // freshly deployed build starts with no saved state

        const newState = { jeopardyPlaying: false, screen: 'BeginScreen' };
        const resultMsg = await distClient.saveStateEdit(conn, build.uuid, JSON.stringify(newState));
        expect(resultMsg.payload).toBe('ack');
        await conn.close();

        // the ack and the registry write are dispatched in the same Elm Cmd.batch, so
        // they aren't guaranteed to land in order — poll rather than read once.
        const entry = await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === build.uuid);
            return found && found.state && found.state.screen === newState.screen ? found : null;
        });
        expect(entry.state).toEqual(newState);
    });

    test('falls back to the previous state when invalid JSON is provided', async () => {
        const invalidJsonBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-3.0.1-universal.dmg',
        });
        const goodState = { jeopardyPlaying: true };

        {
            const { conn } = await distClient.requestStateEdit(TEST_PORT, admin, invalidJsonBuild.uuid);
            const saveResult = await distClient.saveStateEdit(conn, invalidJsonBuild.uuid, JSON.stringify(goodState));
            expect(saveResult.payload).toBe('ack');
            await conn.close();
        }

        const { authResult, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, invalidJsonBuild.uuid);
        expect(authResult.success).toBe(true);
        expect(JSON.parse(json)).toEqual(goodState);

        const resultMsg = await distClient.saveStateEdit(conn, invalidJsonBuild.uuid, 'this is not valid json');
        expect(resultMsg.payload).toBe('stateRequestRejected');
        expect(resultMsg.stateRequestRejected.reason).toBe('invalid json');
        await conn.close();

        // no new write happens on this path, so this checks the earlier successful save —
        // polling anyway for consistency with the rest of this suite rather than assuming
        // enough time has already passed.
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === invalidJsonBuild.uuid));
        expect(entry.state).toEqual(goodState); // unchanged — no write happened
    });
});
