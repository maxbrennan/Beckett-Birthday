'use strict';

const registryHelper = require('../helpers/registry');
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19457;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const WIN_TEXT = 'Text "creeper... awwww man" to Max to claim your reward!';

let server;
let admin;

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
}

// quizQuestions is per-build (see #77): each deploy sends its own quizQuestions on
// distComplete/distReplaceComplete rather than the server reading one shared config file
// at startup. These tests exercise that two builds' answers are validated independently,
// on top of quiz-answer.test.js's single-build decideAnswer coverage from #70/#54.
describe('per-build quiz questions', () => {
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

    test('deploy stores quizQuestions on the registry entry', async () => {
        const quizQuestions = [{ answers: ['only answer'] }];
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-questions-store.dmg',
            winText: WIN_TEXT,
            quizQuestions,
        });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));
        expect(entry.quizQuestions).toEqual(quizQuestions);
    });

    test('two builds deployed with different question sets validate answers independently', async () => {
        const buildA = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-questions-a.dmg',
            winText: WIN_TEXT,
            quizQuestions: [{ answers: ['alpha answer'] }],
        });
        const buildB = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-questions-b.dmg',
            winText: WIN_TEXT,
            quizQuestions: [{ answers: ['beta answer'] }],
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === buildA.uuid));
        await waitUntil(() => readRegistry().find((e) => e.uuid === buildB.uuid));

        const { conn: connA } = await connectAsPlayer(TEST_PORT, buildA.uuid);
        // Build B's own correct answer is wrong for build A's question 0.
        connA.send({ quizAnswerSubmitted: { idx: 0, answer: 'beta answer' } });
        const resultA = await connA.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(resultA.quizAnswerResult.correct).toBe(false);
        await connA.close();

        const { conn: connB } = await connectAsPlayer(TEST_PORT, buildB.uuid);
        connB.send({ quizAnswerSubmitted: { idx: 0, answer: 'beta answer' } });
        const resultB = await connB.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(resultB.quizAnswerResult.correct).toBe(true);
        await connB.close();
    });

    // Unlike winText's inherit-on-replace behavior, quizQuestions is resent fresh on
    // every replace deploy (see #77) -- a replacement build's answers must validate
    // against the newly-sent set, not the uuid-being-replaced's original set.
    test('a replacement build validates answers against the newly-sent set, not the original', async () => {
        const original = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-questions-orig.dmg',
            winText: WIN_TEXT,
            quizQuestions: [{ answers: ['original answer'] }],
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === original.uuid));

        const replacement = await distClient.replaceBuild(TEST_PORT, admin, original.uuid, {
            platform: 'mac',
            filename: 'quiz-questions-replacement.dmg',
            winText: WIN_TEXT,
            quizQuestions: [{ answers: ['replacement answer'] }],
        });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === replacement.uuid));
        expect(entry.quizQuestions).toEqual([{ answers: ['replacement answer'] }]);

        // A replacement starts locked pending an admin state edit (see
        // deploy-replacement.test.js) -- resolve it before a player can connect.
        const { authResult: editAuth, conn: editConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, replacement.uuid);
        expect(editAuth.success).toBe(true);
        await distClient.saveStateEdit(editConn, replacement.uuid, json);
        await editConn.close();
        await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === replacement.uuid);
            return found && found.pendingStateEdit === false ? found : null;
        });

        // Note: a wrong answer now gates the player into the IQ test (see #74's
        // IncorrectAnswer -> setIqTimer change) before they can resubmit the same
        // question, so this test only checks the replacement's own answer set is
        // what actually validates -- the generic "wrong answer rejected" behavior
        // is already covered by quiz-answer.test.js.
        const { conn } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        conn.send({ quizAnswerSubmitted: { idx: 0, answer: 'replacement answer' } });
        const accepted = await conn.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(accepted.quizAnswerResult.correct).toBe(true);
        await conn.close();
    }, 10000);
});
