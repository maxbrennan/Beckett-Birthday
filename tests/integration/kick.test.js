'use strict';

const registryHelper = require('../helpers/registry');
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
    return registryHelper.readRegistry(server.tempDir);
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

    test('starting a state edit kicks the live player, and a successful save delivers the edited quizProgress on reconnect', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-kick-edit.dmg',
        });

        const { conn: playerConn, result: initialResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(initialResult.payload).toBe('stateUpdate');
        // A fresh player has no live iqTimer and no confirmed quiz progress, so the
        // screen is synthesized fresh as BlankScreen 0, always wrapped in BeginScreen.
        expect(JSON.parse(initialResult.stateUpdate.json)).toEqual({ tag: 'BeginScreen', nextScreen: { tag: 'BlankScreen', idx: 0 } });

        const { authResult, conn: adminConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        // the fetched document is the merged server-state blob (winText, iqTimer,
        // quizProgress, timerEndsAt, quizQuestions) -- there is no separate screen
        // field at all; the screen is always derived fresh from these.
        const fetched = JSON.parse(json);
        expect(fetched.quizProgress).toBe(0);

        // starting the edit kicks the live player — its connection closes without any
        // further message from the server.
        await playerConn.closed();

        // while the edit is in flight, a reconnect attempt with the same uuid is rejected.
        const { result: duringEditResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(duringEditResult.payload).toBe('stateRequestRejected');
        expect(duringEditResult.stateRequestRejected.reason).toBe('state is being edited by admin');

        const newState = { ...fetched, quizProgress: 1 };
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify(newState));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await adminConn.close();

        // after the save completes, reconnecting derives the screen from the edited
        // quizProgress directly.
        const { result: afterSaveResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(afterSaveResult.payload).toBe('stateUpdate');
        expect(JSON.parse(afterSaveResult.stateUpdate.json)).toEqual({ tag: 'BeginScreen', nextScreen: { tag: 'BlankScreen', idx: 1 } });
    });

    test('editing a player\'s iqTimer directly: the reconnect wraps the derived IQ screen in BeginScreen', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-edit-midgame.dmg',
        });

        const { conn: adminConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        const fetched = JSON.parse(json);
        const editedIqTimer = {
            epoch: 0,
            phase: 'IqCounting',
            questionIdx: 0,
            countdownRemaining: 5,
            dingCount: 0,
            totalDings: 5,
            fakeFlashPoint: 2,
            fakeFlashUsed: false,
            in50PercentPhase: false,
            lastDing: 'RealDing',
            dingDelay: null,
        };
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify({ ...fetched, iqTimer: editedIqTimer }));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await adminConn.close();

        // There's no "already BeginScreen" case anymore -- every connect derives the
        // screen fresh from iqTimer/quizProgress and wraps it unconditionally, so a
        // mid-game IQ screen resumes via the jeopardy Start flow rather than being
        // dropped straight into the countdown.
        const { result } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(result.payload).toBe('stateUpdate');
        const delivered = JSON.parse(result.stateUpdate.json);
        expect(delivered.tag).toBe('BeginScreen');
        expect(delivered.nextScreen.tag).toBe('IQTestCountdownScreen');
        expect(delivered.nextScreen.state).toEqual({ questionIdx: 0, totalDings: 5, countdown: 5 });
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

    test('a player mid-IQ-test is left untouched on server stop, rehydrated from iqTimer, and snapshotted to resume on rejoin after restart', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-kick-serverstop.dmg',
        });

        const { conn: playerConn, result: initialResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(initialResult.payload).toBe('stateUpdate');

        // Enter the real IQ-test flow (not a raw self-report -- ClientStateUpdate no
        // longer persists anything at all) so the server genuinely owns a live
        // iqTimer for this uuid.
        playerConn.send({ iqStartCountdown: {} });

        // The server-owned iqTimer snapshot lands in the registry as its own field,
        // never as a persisted screen (there is no persisted screen at all anymore).
        const afterUpdate = await waitForRegistryEntry(build.uuid, (e) => e.iqTimer && e.iqTimer.phase);
        expect(afterUpdate.iqTimer.phase).toBe('IqCounting');

        // Stop the server (keeping the temp dir so the same registry survives the restart).
        // wss.close() doesn't tear down the live socket, so no disconnect fires — the point
        // being that the live iqTimer is NOT cleared at shutdown.
        await server.stop({ keepData: true });
        await playerConn.closed();

        // Restart against the same registry: FileRead rehydrates model.iqTimers from
        // the persisted iqTimer field (see Server.elm's init/FileRead), and reconnecting
        // derives the screen fresh from it, wrapped in BeginScreen.
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });
        const { result: resumeResult } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(resumeResult.payload).toBe('stateUpdate');
        const resumed = JSON.parse(resumeResult.stateUpdate.json);
        expect(resumed.tag).toBe('BeginScreen');
        expect(resumed.nextScreen.tag).toBe('IQTestCountdownScreen');
    }, 20000);
});
