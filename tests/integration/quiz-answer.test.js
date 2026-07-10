'use strict';

const fs = require('fs');
const path = require('path');
const { startTestServer, TEST_QUIZ_QUESTION_COUNT } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19455;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const WIN_TEXT = 'Text "creeper... awwww man" to Max to claim your reward!';

let server;
let admin;

function readRegistry() {
    const file = path.join(server.tempDir, 'app-builds', 'builds.jsonl');
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

// Regression test for issue #54/#32: the server, not the client, must hold the
// answers (testServer.js's TEST_QUIZ_QUESTIONS: idx 0 -> "answer zero", idx 1
// -> "answer one") and decide correctness -- the client only ever gets
// config/quiz-manifest.json (no answers). This drives the real
// quizAnswerSubmitted -> quizAnswerResult round trip end to end.
describe('server-side quiz answer validation', () => {
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

    test('a correct answer (fuzzy-matched, see normalize) replies correct=true and advances progress', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-answer-correct.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ quizAnswerSubmitted: { idx: 0, answer: '  Answer Zero!! ' } });
        const result = await conn.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(result.quizAnswerResult.idx).toBe(0);
        expect(result.quizAnswerResult.correct).toBe(true);

        const entry = await waitUntil(() => {
            const e = readRegistry().find((row) => row.uuid === build.uuid);
            return e && e.quizProgress === 1 ? e : undefined;
        });
        expect(entry.quizProgress).toBe(1);

        await conn.close();
    }, 10000);

    test('an incorrect answer replies correct=false with the reveal text and does not advance progress', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-answer-incorrect.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ quizAnswerSubmitted: { idx: 0, answer: 'not even close' } });
        const result = await conn.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(result.quizAnswerResult.idx).toBe(0);
        expect(result.quizAnswerResult.correct).toBe(false);
        // Capitalized, mirroring the old client-side View.elm behavior.
        expect(result.quizAnswerResult.revealAnswer).toBe('Answer zero');

        // No quizAnswerResult reveals the answer for a *different*, unearned question --
        // progress must still read as untouched (0 / absent).
        const entry = readRegistry().find((row) => row.uuid === build.uuid);
        expect(entry && entry.quizProgress).toBeFalsy();

        await conn.close();
    }, 10000);

    test('a skip-ahead idx (out of order) gets no reply at all -- silently ignored', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-answer-skip-ahead.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        // Jump straight to question 1 without having passed question 0 -- even with
        // the *correct* answer for question 1, this must not be honored.
        conn.send({ quizAnswerSubmitted: { idx: 1, answer: 'answer one' } });
        await expect(conn.waitFor((m) => m.payload === 'quizAnswerResult', 500)).rejects.toThrow();

        await conn.close();
    }, 10000);

    test('answering every question in order eventually grants winText', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-answer-full-run.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        const answers = ['answer zero', 'answer one'];
        expect(answers.length).toBe(TEST_QUIZ_QUESTION_COUNT);

        for (let idx = 0; idx < answers.length; idx += 1) {
            conn.send({ quizAnswerSubmitted: { idx, answer: answers[idx] } });
            const result = await conn.waitFor((m) => m.payload === 'quizAnswerResult');
            expect(result.quizAnswerResult.correct).toBe(true);
        }

        const winMsg = await conn.waitFor((m) => m.payload === 'winText');
        expect(winMsg.winText.text).toBe(WIN_TEXT);

        await conn.close();
    }, 10000);
});
