'use strict';

const fs = require('fs');
const path = require('path');
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');

const TEST_PORT = 19450;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;

function readRegistry() {
    const file = path.join(server.tempDir, 'app-builds', 'builds.jsonl');
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

// The registry writeFile port and the WebSocket reply are independent Cmds in the same
// batch, so the reply can arrive before the file lands. Poll the on-disk registry until
// the entry for `uuid` satisfies `predicate` (or time out and return whatever's there).
async function waitForRegistryEntry(uuid, predicate, timeoutMs = 3000) {
    const start = Date.now();
    let entry = readRegistry().find((e) => e.uuid === uuid);
    while (!(entry && predicate(entry)) && Date.now() - start < timeoutMs) {
        await new Promise((r) => setTimeout(r, 25));
        entry = readRegistry().find((e) => e.uuid === uuid);
    }
    return entry;
}

// Server-stop is destructive (the shared server can't serve any later test), so it runs
// last in this file; the two kick scenarios each deploy their own build and don't share
// state with each other.
describe('kick behavior', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
        admin = new AdminClient({ username: USERNAME, password: PASSWORD });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('starting a state edit kicks the live player, and a successful save delivers the edited state on reconnect', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-kick-edit.dmg',
        });

        const { conn: playerConn, result: initialResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(initialResult.payload).toBe('stateUpdate');
        expect(JSON.parse(initialResult.stateUpdate.json)).toEqual({});

        const { authResult, conn: adminConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        expect(JSON.parse(json)).toEqual({});

        // starting the edit kicks the live player — its connection closes without any
        // further message from the server.
        await playerConn.closed();

        // while the edit is in flight, a reconnect attempt with the same uuid is rejected.
        const { result: duringEditResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(duringEditResult.payload).toBe('stateRequestRejected');
        expect(duringEditResult.stateRequestRejected.reason).toBe('state is being edited by admin');

        const newState = { jeopardyPlaying: false, screen: 'BeginScreen' };
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify(newState));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await adminConn.close();

        // after the save completes, reconnecting delivers the edited state.
        const { result: afterSaveResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(afterSaveResult.payload).toBe('stateUpdate');
        expect(JSON.parse(afterSaveResult.stateUpdate.json)).toEqual(newState);
    });

    // The two tests below pin the intended rejoin behavior for admin-edited state, using the
    // real `{ tag: … }` screen shape (the reconnect test above uses an opaque string screen,
    // which sidesteps the BeginScreen-vs-mid-game branch this behavior actually turns on).
    test('editing a player onto a mid-game screen: the reconnect resumes via BeginScreen with that screen stowed in savedState', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-edit-midgame.dmg',
        });

        const midGameState = { screen: { tag: 'QuizScreen' }, pending: [], now: 1234, jeopardyPlaying: false, savedState: null };
        const { conn: adminConn } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify(midGameState));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await adminConn.close();

        // The edited screen isn't BeginScreen, so the reconnect snapshots it: reset to
        // BeginScreen and stow the mid-game screen under savedState, so the player resumes
        // via the jeopardy Start flow rather than being dropped straight into the quiz.
        const { result } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(result.payload).toBe('stateUpdate');
        const delivered = JSON.parse(result.stateUpdate.json);
        expect(delivered.screen.tag).toBe('BeginScreen');
        expect(delivered.jeopardyPlaying).toBe(true);
        expect(delivered.savedState.screen.tag).toBe('QuizScreen');
    });

    test('editing a player onto a BeginScreen state: the reconnect delivers it verbatim, savedState preserved', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-edit-begin.dmg',
        });

        // A BeginScreen state that already carries a savedState (e.g. an admin parking a
        // player at the resume prompt for a specific screen).
        const beginState = {
            screen: { tag: 'BeginScreen' },
            jeopardyPlaying: true,
            pending: [],
            savedState: { screen: { tag: 'QuizScreen' }, pending: [], savedAt: 500, songResumeTime: null, videoResumeTime: null },
        };
        const { conn: adminConn } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify(beginState));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await adminConn.close();

        // Already on BeginScreen, so the reconnect delivers it untouched — no re-snapshot,
        // and the existing savedState is carried through rather than clobbered.
        const { result } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(result.payload).toBe('stateUpdate');
        expect(JSON.parse(result.stateUpdate.json)).toEqual(beginState);
    });

    test('undeploying kicks the live player, and reconnecting with the now-unregistered uuid is rejected', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-kick-undeploy.dmg',
        });

        const { conn: playerConn, result: initialResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(initialResult.payload).toBe('stateUpdate');

        const { authResult, ack } = await distClient.undeploy(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        expect(ack).toBeTruthy();

        await playerConn.closed();

        // the build's uuid no longer exists in the registry, and this test server runs in
        // production mode, so a fresh connection attempt is rejected as unknown — a
        // protocol-level proxy for "the application fails to run" after undeploy.
        const { result: reconnectResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(reconnectResult.payload).toBe('stateRequestRejected');
        expect(reconnectResult.stateRequestRejected.reason).toBe('unknown uuid');
    });

    test('a player mid-game is left untouched on server stop, then snapshotted to resume on rejoin after restart', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-kick-serverstop.dmg',
        });

        const { conn: playerConn, result: initialResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(initialResult.payload).toBe('stateUpdate');

        // Advance the player past BeginScreen and persist that mid-game state.
        const midGameState = { screen: { tag: 'IQTestActiveScreen' }, pending: [], now: 1234, jeopardyPlaying: false, savedState: null };
        playerConn.send({ stateUpdate: { json: JSON.stringify(midGameState) } });
        await playerConn.waitFor((m) => m.payload === 'stateUpdateAck');

        // On disk the state is left exactly as the player saved it: still IQTest, no
        // savedState. Nothing snapshots it — not on the update, and (below) not on the way down.
        const afterUpdate = await waitForRegistryEntry(build.uuid, (e) => e.state && e.state.screen);
        expect(afterUpdate.state.screen.tag).toBe('IQTestActiveScreen');
        expect(afterUpdate.state.savedState).toBeNull();

        // Stop the server (keeping the temp dir so the same registry survives the restart).
        // wss.close() doesn't tear down the live socket, so no disconnect fires — the point
        // being that the mid-game state is NOT snapshotted at shutdown.
        await server.stop({ keepData: true });
        await playerConn.closed();

        // Restart against the same registry and reconnect: the stateRequest lazily snapshots
        // the mid-game screen into savedState and resets to BeginScreen, and delivers that.
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });
        const { result: resumeResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(resumeResult.payload).toBe('stateUpdate');
        const resumed = JSON.parse(resumeResult.stateUpdate.json);
        expect(resumed.screen.tag).toBe('BeginScreen');
        expect(resumed.jeopardyPlaying).toBe(true);
        expect(resumed.savedState.screen.tag).toBe('IQTestActiveScreen');

        // …and the snapshot is now persisted, so it survives a further restart too.
        const afterRejoin = await waitForRegistryEntry(build.uuid, (e) => e.state && e.state.screen.tag === 'BeginScreen');
        expect(afterRejoin.state.screen.tag).toBe('BeginScreen');
        expect(afterRejoin.state.savedState.screen.tag).toBe('IQTestActiveScreen');
    }, 20000);
});
