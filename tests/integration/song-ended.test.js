'use strict';

const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');
const registryHelper = require('../helpers/registry');

const TEST_PORT = 19456;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
}

// The server only evicts a uuid from connectedPlayers once it processes the WS 'close'
// event for the old connection, which can land slightly after the client's own close()
// resolves. A reconnect attempt in that window is correctly rejected as "duplicate uuid",
// so retry rather than racing it with a fixed sleep (see timer.test.js's identical helper).
async function reconnectAsPlayer(port, uuid, { timeoutMs = 2000 } = {}) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const attempt = await connectAsPlayer(port, uuid);
        if (attempt.result.payload === 'stateUpdate') return attempt;
        await attempt.conn.close();
        if (Date.now() > deadline) {
            throw new Error('reconnectAsPlayer: timed out — uuid still marked connected');
        }
        await new Promise((r) => setTimeout(r, 20));
    }
}

// The server never accepts an answer for idx until it has itself recorded a
// matching quizSongEnded report for that idx (see Server.elm's Model.quizSongEnded /
// the ClientQuizAnswerSubmitted gate) -- closing a gap where a crafted client could
// otherwise submit before any song ever played.
describe('server-tracked song-ended -> answer gate', () => {
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

    test('a matching quizSongEnded report is tracked and acked', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'song-ended-ack.dmg',
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ quizSongEnded: { idx: 0 } });
        const ack = await conn.waitFor((m) => m.payload === 'quizSongEndedAck');
        expect(ack.quizSongEndedAck.idx).toBe(0);

        await conn.close();
    }, 10000);

    test('an answer submitted with no prior quizSongEnded report is ignored', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'song-ended-missing.dmg',
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ quizAnswerSubmitted: { idx: 0, answer: 'answer zero' } });
        await expect(conn.waitFor((m) => m.payload === 'quizAnswerResult', 500)).rejects.toThrow();

        await conn.close();
    }, 10000);

    test('sending the matching quizSongEnded first lets the same submission succeed', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'song-ended-then-answer.dmg',
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ quizSongEnded: { idx: 0 } });
        await conn.waitFor((m) => m.payload === 'quizSongEndedAck');

        conn.send({ quizAnswerSubmitted: { idx: 0, answer: 'answer zero' } });
        const result = await conn.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(result.quizAnswerResult.correct).toBe(true);

        await conn.close();
    }, 10000);

    test('an out-of-order quizSongEnded report is ignored and does not unlock the answer', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'song-ended-out-of-order.dmg',
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        // Question 0 hasn't been earned yet -- reporting idx 1's song ended must be
        // rejected, since the player's current expected question is still 0.
        conn.send({ quizSongEnded: { idx: 1 } });
        await expect(conn.waitFor((m) => m.payload === 'quizSongEndedAck', 500)).rejects.toThrow();

        conn.send({ quizAnswerSubmitted: { idx: 0, answer: 'answer zero' } });
        await expect(conn.waitFor((m) => m.payload === 'quizAnswerResult', 500)).rejects.toThrow();

        await conn.close();
    }, 10000);

    // A reconnect clears the server's confirmation for the uuid (see
    // ClientStateRequest), so a bare resubmit without re-reporting is rejected --
    // this is why the real Elm client's resumeCmd re-sends quizSongEnded itself
    // when it resumes directly onto a saved QuestionScreen (see MainTest.elm's
    // "resumeCmd" suite), without ever replaying the song. This raw-protocol test
    // can't drive that client behavior directly, but it proves both halves: the
    // bare resubmit is rejected, and replaying what resumeCmd does (re-sending
    // quizSongEnded once, right after reconnecting) fully recovers the player.
    test('a reconnect clears a previously-confirmed idx, requiring a fresh report -- which resumeCmd supplies', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'song-ended-reconnect.dmg',
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const first = await connectAsPlayer(TEST_PORT, build.uuid);
        first.conn.send({ quizSongEnded: { idx: 0 } });
        await first.conn.waitFor((m) => m.payload === 'quizSongEndedAck');
        await first.conn.close();

        const second = await reconnectAsPlayer(TEST_PORT, build.uuid);
        second.conn.send({ quizAnswerSubmitted: { idx: 0, answer: 'answer zero' } });
        await expect(second.conn.waitFor((m) => m.payload === 'quizAnswerResult', 500)).rejects.toThrow();

        // What the real client's resumeCmd does automatically on resuming a saved
        // QuestionScreen: re-report the song as ended for the same idx.
        second.conn.send({ quizSongEnded: { idx: 0 } });
        await second.conn.waitFor((m) => m.payload === 'quizSongEndedAck');
        second.conn.send({ quizAnswerSubmitted: { idx: 0, answer: 'answer zero' } });
        const recovered = await second.conn.waitFor((m) => m.payload === 'quizAnswerResult');
        expect(recovered.quizAnswerResult.correct).toBe(true);

        await second.conn.close();
    }, 10000);
});
