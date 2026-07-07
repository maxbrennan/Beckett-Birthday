'use strict';

// Reproduces and verifies the fix for a reported bug: starting the IQ countdown,
// then using the admin edit:state tool to lower the persisted countdown, then
// reconnecting and resuming, used to still show the original countdown -- the
// server's in-memory iqTimers (the sole timing authority) was never told about
// the edit, so it silently clobbered it on the next resend. See
// Server.elm's reconcileIqTimerAfterEdit.

const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { connectAsPlayer } = require('./helpers/playerClient');

const TEST_PORT = 19472;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;

// Mirrors the shape src/Sync.elm's encodeModel/encodeScreen produce for a player
// mid pre-test countdown, the fields edit:state would show an admin.
function iqCountdownState(uuid, { questionIdx = 0, totalDings = 100, countdown }) {
    return JSON.stringify({
        screen: { tag: 'IQTestCountdownScreen', state: { questionIdx, totalDings, countdown } },
        jeopardyPlaying: true,
        now: 0,
        pending: [],
        savedState: null,
        dingKey: 0,
        pendingStartTime: null,
        wsClientId: null,
        timerEndsAt: 0,
    });
}

describe('IQ timer reconciliation after an admin state edit', () => {
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

    test('editing the countdown down takes effect on the next resume, not the stale server value', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {});
        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);

        // Start the real server-driven countdown (from iqQuestionCount == 100) and
        // let a tick land, then persist that as the player's live state -- exactly
        // what the real client's periodic WsSyncTick does.
        conn.send({ iqStartCountdown: {} });
        const isTick = (m) => m.payload === 'iqCountdownTick';
        const firstTick = await conn.waitFor(isTick, 3000);
        conn.send({ stateUpdate: { json: iqCountdownState(build.uuid, { countdown: firstTick.iqCountdownTick.remaining }) } });
        await conn.waitFor((m) => m.payload === 'ack');

        // Admin edits state: this kicks the player (closeClient -> ClientDisconnected,
        // pausing the server's iqTimers entry) and hands back the just-persisted JSON.
        const { authResult, conn: adminConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        const parsed = JSON.parse(json);
        expect(parsed.screen.tag).toBe('IQTestCountdownScreen');

        // Lower the countdown to 5 and save.
        parsed.screen.state.countdown = 5;
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify(parsed));
        expect(saveResult.payload).toBe('ack');
        await adminConn.close();

        // Reconnect as the same player and resume (mirrors the client's BeginPressed
        // sending iqResume right after restoring the saved screen).
        const { conn: reconnected } = await connectAsPlayer(TEST_PORT, build.uuid);
        try {
            reconnected.send({ iqResume: {} });
            const resumedTick = await reconnected.waitFor(isTick, 3000);

            // The edit took effect -- not the original ~99 the server had in memory.
            expect(resumedTick.iqCountdownTick.remaining).toBe(5);
        } finally {
            await reconnected.close();
        }
    }, 15000);

    test('an edit also survives a server restart, not just a same-process resume', async () => {
        // Regression test for an ordering bug in the fix above: the
        // ClientDistStateEditSave handler used to compute the raw-edited registry
        // and the reconciled iqTimers from the same pre-edit model, then did
        // `{ reconciledModel | registry = newRegistry }` -- which silently
        // discarded whatever reconcileIqTimerAfterEdit had put in .registry (its
        // iqTimer snapshot and re-derived screen). That meant the edit took
        // effect for an in-memory resume (same process) but would have been lost
        // on the very next restart's rehydration from builds.jsonl.
        const build = await distClient.deployBuild(TEST_PORT, admin, {});
        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);

        conn.send({ iqStartCountdown: {} });
        const isTick = (m) => m.payload === 'iqCountdownTick';
        const firstTick = await conn.waitFor(isTick, 3000);
        conn.send({ stateUpdate: { json: iqCountdownState(build.uuid, { countdown: firstTick.iqCountdownTick.remaining }) } });
        await conn.waitFor((m) => m.payload === 'ack');

        const { authResult, conn: adminConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        const parsed = JSON.parse(json);
        expect(parsed.screen.tag).toBe('IQTestCountdownScreen');

        parsed.screen.state.countdown = 7;
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify(parsed));
        expect(saveResult.payload).toBe('ack');
        await adminConn.close();

        // Restart (rather than just reconnecting) so the rehydration in
        // Server.elm's init/FileRead is what has to carry the edit forward.
        await server.stop({ keepData: true });
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });

        const { conn: reconnected } = await connectAsPlayer(TEST_PORT, build.uuid);
        try {
            reconnected.send({ iqResume: {} });
            const resumedTick = await reconnected.waitFor(isTick, 3000);

            expect(resumedTick.iqCountdownTick.remaining).toBe(7);
        } finally {
            await reconnected.close();
        }
    }, 20000);
});
