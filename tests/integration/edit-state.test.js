'use strict';

const registryHelper = require('../helpers/registry');
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19449;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;
let build;

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
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
        expect(entry.quizProgress).toBe(0);
    });

    test('successfully edits quizProgress when a uuid is provided', async () => {
        const { authResult, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        // the fetched document is the merged server-state blob (winText, iqTimer,
        // quizProgress, timerEndsAt, quizQuestions) -- there is no separate screen
        // field; the screen is always derived fresh from these.
        const fetched = JSON.parse(json);
        expect(fetched.quizProgress).toBe(0); // freshly deployed build starts unearned

        const newState = { ...fetched, quizProgress: 1 };
        const resultMsg = await distClient.saveStateEdit(conn, build.uuid, JSON.stringify(newState));
        expect(resultMsg.payload).toBe('distStateEditSaveAck');
        await conn.close();

        // the ack and the registry write are dispatched in the same Elm Cmd.batch, so
        // they aren't guaranteed to land in order — poll rather than read once.
        const entry = await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === build.uuid);
            return found && found.quizProgress === 1 ? found : null;
        });
        expect(entry.quizProgress).toBe(1);
    });

    test('falls back to the previous quizProgress when invalid JSON is provided', async () => {
        const invalidJsonBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-3.0.1-universal.dmg',
        });

        {
            const { conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, invalidJsonBuild.uuid);
            const goodState = { ...JSON.parse(json), quizProgress: 1 };
            const saveResult = await distClient.saveStateEdit(conn, invalidJsonBuild.uuid, JSON.stringify(goodState));
            expect(saveResult.payload).toBe('distStateEditSaveAck');
            await conn.close();
        }

        const { authResult, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, invalidJsonBuild.uuid);
        expect(authResult.success).toBe(true);
        expect(JSON.parse(json).quizProgress).toBe(1);

        const resultMsg = await distClient.saveStateEdit(conn, invalidJsonBuild.uuid, 'this is not valid json');
        expect(resultMsg.payload).toBe('stateRequestRejected');
        expect(resultMsg.stateRequestRejected.reason).toBe('invalid json');
        await conn.close();

        // no new write happens on this path, so this checks the earlier successful save —
        // polling anyway for consistency with the rest of this suite rather than assuming
        // enough time has already passed.
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === invalidJsonBuild.uuid));
        expect(entry.quizProgress).toBe(1); // unchanged — no write happened
    });

    // Issue #74: an edit onto a quiz-slide screen must also move the server's own
    // quizProgress, or acceptQuizAdvance keeps expecting the pre-edit question and
    // silently rejects every answer the edited-onto screen produces, stranding the
    // player. quizProgress is now a real field the admin sets directly (see
    // Server.elm's ClientDistStateEditSave), not inferred from the screen's shape.
    test('an edit setting quizProgress directly lets the player answer that question', async () => {
        const quizEditBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-3.0.2-universal.dmg',
        });

        {
            const { conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, quizEditBuild.uuid);
            const editedState = { ...JSON.parse(json), quizProgress: 1 };
            const saveResult = await distClient.saveStateEdit(conn, quizEditBuild.uuid, JSON.stringify(editedState));
            expect(saveResult.payload).toBe('distStateEditSaveAck');
            await conn.close();
        }

        // The edited idx is now the authoritative progress: question 1's answer (see
        // testServer.js's TEST_QUIZ_QUESTIONS) must be accepted, not silently dropped.
        const { conn } = await connectAsPlayer(TEST_PORT, quizEditBuild.uuid);
        conn.send({ quizSongEnded: { idx: 1 } });
        await conn.waitFor((m) => m.payload === 'quizSongEndedAck');
        conn.send({ quizAnswerSubmitted: { idx: 1, answer: 'answer one' } });
        const result = await conn.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(result.quizAnswerResult.correct).toBe(true);
        await conn.close();

        const entry = await waitUntil(() => {
            const e = readRegistry().find((row) => row.uuid === quizEditBuild.uuid);
            return e && e.quizProgress === 2 ? e : undefined;
        });
        expect(entry.quizProgress).toBe(2);
    }, 10000);

    // Issue #52: starting edit:state while a ding is actively shown to a connected
    // player must not let an unchanged save clobber the disconnect-triggered rewind
    // (IqDingShown -> IqDingScheduled, see #63) with the pre-rewind snapshot.
    // performStateEdit reads the player's state *before* closeClient's kick actually
    // reaches ClientDisconnected (a separate, later message) -- without its own
    // proactive rewind, the admin would be handed (and could resave) a stale
    // "IqDingShown" snapshot, resurrecting the already-cleared ding on reconnect.
    test('an unchanged edit:state save while a ding is showing does not resurrect it on reconnect', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-3.0.3-universal.dmg',
        });

        const shownIqTimer = {
            epoch: 1,
            phase: 'IqDingShown',
            questionIdx: 0,
            countdownRemaining: 0,
            dingCount: 3,
            totalDings: 100,
            fakeFlashPoint: 9999,
            fakeFlashUsed: false,
            in50PercentPhase: false,
            lastDing: 'RealDing',
            dingDelay: 6.5,
        };

        // Stage the ding as already showing, before any player connects.
        {
            const { conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
            const edited = { ...JSON.parse(json), iqTimer: shownIqTimer };
            const saveResult = await distClient.saveStateEdit(conn, build.uuid, JSON.stringify(edited));
            expect(saveResult.payload).toBe('distStateEditSaveAck');
            await conn.close();
        }

        // Connect as the player: the server derives the ding actively flashing.
        const { conn: playerConn, result: firstState } = await connectAsPlayer(TEST_PORT, build.uuid);
        const firstScreen = JSON.parse(firstState.stateUpdate.json);
        expect(firstScreen.nextScreen.tag).toBe('IQTestActiveScreen');
        expect(firstScreen.nextScreen.state.isFlashing).toBe(true);
        expect(firstScreen.nextScreen.state.dingActive).toBe(true);
        expect(firstScreen.nextScreen.state.dingCount).toBe(3);

        // Admin starts edit:state while the player is still connected and mid-ding.
        // This kicks the player (playerConn closes) -- the fix means the snapshot
        // handed back here is already rewound, not the raw IqDingShown above.
        const { authResult, conn: adminConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        const fetched = JSON.parse(json);
        expect(fetched.iqTimer.phase).toBe('IqDingScheduled');
        expect(fetched.iqTimer.dingDelay).toBe(6.5);
        expect(fetched.iqTimer.dingCount).toBe(3);

        await playerConn.closed();

        // Make no changes and save.
        const saveResult = await distClient.saveStateEdit(adminConn, build.uuid, JSON.stringify(fetched));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await adminConn.close();

        // Reconnect as the same player: the ding must not still be showing, and the
        // count must be exactly what it was before -- not resent/re-counted.
        const { conn: reconnected, result: secondState } = await connectAsPlayer(TEST_PORT, build.uuid);
        try {
            const secondScreen = JSON.parse(secondState.stateUpdate.json);
            expect(secondScreen.nextScreen.tag).toBe('IQTestActiveScreen');
            expect(secondScreen.nextScreen.state.isFlashing).toBe(false);
            expect(secondScreen.nextScreen.state.dingActive).toBe(false);
            expect(secondScreen.nextScreen.state.dingCount).toBe(3);
        } finally {
            await reconnected.close();
        }

        const entry = await waitUntil(() => {
            const e = readRegistry().find((row) => row.uuid === build.uuid);
            return e && e.iqTimer && e.iqTimer.phase === 'IqDingScheduled' ? e : null;
        });
        expect(entry.iqTimer.dingCount).toBe(3);
    }, 15000);
});
