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
        expect(entry.state).toBeFalsy();
    });

    test('successfully edits the state when a uuid is provided', async () => {
        const { authResult, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        // the fetched document is the whole merged server-state blob (screen, winText,
        // iqTimer, quizProgress, timerEndsAt, quizQuestions), not just the raw screen.
        const fetched = JSON.parse(json);
        expect(fetched.state).toBeNull(); // freshly deployed build starts with no saved state

        const editedScreen = { tag: 'BeginScreen', nextScreen: { tag: 'BlankScreen', idx: 0 } };
        const newState = { ...fetched, state: editedScreen };
        const resultMsg = await distClient.saveStateEdit(conn, build.uuid, JSON.stringify(newState));
        expect(resultMsg.payload).toBe('distStateEditSaveAck');
        await conn.close();

        // the ack and the registry write are dispatched in the same Elm Cmd.batch, so
        // they aren't guaranteed to land in order — poll rather than read once.
        const entry = await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === build.uuid);
            return found && found.state && found.state.tag === editedScreen.tag ? found : null;
        });
        expect(entry.state).toEqual(editedScreen);
    });

    test('falls back to the previous state when invalid JSON is provided', async () => {
        const invalidJsonBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-3.0.1-universal.dmg',
        });
        const goodScreen = { tag: 'BeginScreen', nextScreen: { tag: 'BlankScreen', idx: 0 } };

        {
            const { conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, invalidJsonBuild.uuid);
            const goodState = { ...JSON.parse(json), state: goodScreen };
            const saveResult = await distClient.saveStateEdit(conn, invalidJsonBuild.uuid, JSON.stringify(goodState));
            expect(saveResult.payload).toBe('distStateEditSaveAck');
            await conn.close();
        }

        const { authResult, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, invalidJsonBuild.uuid);
        expect(authResult.success).toBe(true);
        expect(JSON.parse(json).state).toEqual(goodScreen);

        const resultMsg = await distClient.saveStateEdit(conn, invalidJsonBuild.uuid, 'this is not valid json');
        expect(resultMsg.payload).toBe('stateRequestRejected');
        expect(resultMsg.stateRequestRejected.reason).toBe('invalid json');
        await conn.close();

        // no new write happens on this path, so this checks the earlier successful save —
        // polling anyway for consistency with the rest of this suite rather than assuming
        // enough time has already passed.
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === invalidJsonBuild.uuid));
        expect(entry.state).toEqual(goodScreen); // unchanged — no write happened
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
            const editedState = { ...JSON.parse(json), state: { tag: 'QuestionScreen', idx: 1, s: '' }, quizProgress: 1 };
            const saveResult = await distClient.saveStateEdit(conn, quizEditBuild.uuid, JSON.stringify(editedState));
            expect(saveResult.payload).toBe('distStateEditSaveAck');
            await conn.close();
        }

        // The edited idx is now the authoritative progress: question 1's answer (see
        // testServer.js's TEST_QUIZ_QUESTIONS) must be accepted, not silently dropped.
        const { conn } = await connectAsPlayer(TEST_PORT, quizEditBuild.uuid);
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
});
