'use strict';

const registryHelper = require('../helpers/registry');
const { startTestServer, TEST_QUIZ_QUESTION_COUNT } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19453;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const WIN_TEXT = 'Text "creeper... awwww man" to Max to claim your reward!';

let server;
let admin;

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
}

// Minimal player state; a raw stateUpdate the fabricated-exploit test uses to simulate a
// modified client bypassing the Elm client's Msg system entirely (see win-text.test.js).
// The persisted/self-reported state *is* the screen's own JSON directly (see Sync.elm's
// encodeModel) -- no wrapping object.
function stateWithScreen(screen) {
    return JSON.stringify(screen);
}

describe('server-side quiz-progress win gating', () => {
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

    test('in-order quizAdvanced events yield winText only after the final question', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-progress-in-order.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);

        for (let idx = 0; idx < TEST_QUIZ_QUESTION_COUNT - 1; idx += 1) {
            conn.send({ quizAdvanced: { idx } });
            // No winText yet -- there's still at least one more question to pass.
            await expect(conn.waitFor((m) => m.payload === 'winText', 300)).rejects.toThrow();
        }

        conn.send({ quizAdvanced: { idx: TEST_QUIZ_QUESTION_COUNT - 1 } });
        const winMsg = await conn.waitFor((m) => m.payload === 'winText');
        expect(winMsg.winText.text).toBe(WIN_TEXT);

        await conn.close();
    }, 10000);

    test('an out-of-order idx (skipping ahead) never produces winText', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-progress-skip-ahead.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        // Jump straight to the last question's index without earning the earlier ones.
        conn.send({ quizAdvanced: { idx: TEST_QUIZ_QUESTION_COUNT - 1 } });
        await expect(conn.waitFor((m) => m.payload === 'winText', 500)).rejects.toThrow();

        await conn.close();
    }, 10000);

    test('a duplicate idx does not double-advance or trigger early completion', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-progress-duplicate.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ quizAdvanced: { idx: 0 } });
        conn.send({ quizAdvanced: { idx: 0 } });
        await expect(conn.waitFor((m) => m.payload === 'winText', 500)).rejects.toThrow();

        const entry = await waitUntil(() => {
            const e = readRegistry().find((row) => row.uuid === build.uuid);
            return e && e.quizProgress === 1 ? e : undefined;
        });
        expect(entry.quizProgress).toBe(1);

        await conn.close();
    }, 10000);

    // Regression test for the fixed exploit (issue #33): a freshly connected player who
    // never sent a single quizAdvanced event crafts a raw stateUpdate claiming the win
    // screen directly, simulating a modified client bypassing the Elm client's Msg system.
    // The server must not grant winText from this self-reported claim alone.
    test('a crafted win-claiming stateUpdate with zero quizAdvanced events never triggers winText', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-progress-exploit.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({
            stateUpdate: {
                json: stateWithScreen({ tag: 'ConfirmingAnswerScreen', nextScreen: { tag: 'WinScreen' } }),
            },
        });
        await conn.waitFor((m) => m.payload === 'stateUpdateAck');
        await expect(conn.waitFor((m) => m.payload === 'winText', 500)).rejects.toThrow();

        await conn.close();
    }, 10000);

    test('completed progress persists into builds.json', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-progress-persist.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        for (let idx = 0; idx < TEST_QUIZ_QUESTION_COUNT; idx += 1) {
            conn.send({ quizAdvanced: { idx } });
        }
        await conn.waitFor((m) => m.payload === 'winText');
        await conn.close();

        // writeRegistry's fs write is async and can land after winText is already
        // delivered over the socket, so poll rather than reading the file exactly once.
        const entry = await waitUntil(() => {
            const e = readRegistry().find((row) => row.uuid === build.uuid);
            return e && e.quizProgress === TEST_QUIZ_QUESTION_COUNT ? e : undefined;
        });
        expect(entry.quizProgress).toBe(TEST_QUIZ_QUESTION_COUNT);
    }, 10000);

    // Issue #74: the persisted quiz-slide screen is server-derived from confirmed
    // progress (Server.elm's deriveQuizScreen), never trusted from the client's raw
    // stateUpdate -- a crafted client can't park itself on an unearned question, and
    // the next delivery resumes at the slide it actually earned.
    test('a crafted unearned quiz-slide stateUpdate is corrected to the server-derived screen on the next delivery', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-progress-derived-screen.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        // Earn exactly one question, keeping progress (1) below the total (2) so the
        // derived screen stays in play.
        conn.send({ quizAdvanced: { idx: 0 } });
        await waitUntil(() => {
            const e = readRegistry().find((row) => row.uuid === build.uuid);
            return e && e.quizProgress === 1 ? e : undefined;
        });

        // Claim a question screen far past the earned one, with a typed answer in tow.
        conn.send({
            stateUpdate: {
                json: stateWithScreen({ tag: 'QuestionScreen', idx: 9, s: 'stolen-answer-peek' }),
            },
        });
        await conn.waitFor((m) => m.payload === 'stateUpdateAck');

        // The persisted screen must be the derived BlankScreen at the earned index,
        // with the crafted screen (and its typed text) gone entirely.
        const entry = await waitUntil(() => {
            const e = readRegistry().find((row) => row.uuid === build.uuid);
            return e && e.state && e.state.tag === 'BlankScreen' ? e : undefined;
        });
        expect(entry.state).toEqual({ tag: 'BlankScreen', idx: 1 });
        expect(JSON.stringify(entry)).not.toContain('stolen-answer-peek');
        await conn.close();

        // Reconnect: mid-game states deliver via the jeopardy snapshot, wrapping the
        // player in BeginScreen while leaving the corrected screen itself in
        // place (see kick.test.js).
        const { conn: reconn, result } = await connectAsPlayer(TEST_PORT, build.uuid);
        const delivered = JSON.parse(result.stateUpdate.json);
        expect(delivered.tag).toBe('BeginScreen');
        expect(delivered.nextScreen).toEqual({ tag: 'BlankScreen', idx: 1 });
        await reconn.close();
    }, 10000);
});
