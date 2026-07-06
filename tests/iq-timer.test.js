'use strict';

// End-to-end check of the server-driven IQ-test timer: pressing "Begin"
// (iqStartCountdown) makes the server run the countdown itself and stream
// iqCountdownTick events, and a disconnect mid-countdown is paused (not lost)
// -- reconnecting and sending iqResume picks the countdown back up, without
// disturbing other connected clients. The full ding/scoring/completion
// progression runs on a real 100 s countdown + 2-15 s ding gaps in production,
// so it is verified by the fast pure elm-test (tests/ServerTest.elm), not here.

const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { connectAsPlayer } = require('./helpers/playerClient');

const TEST_PORT = 19471;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

// Mirrors src/Game/IQTest.elm iqQuestionCount (production value); the countdown
// starts here and the first tick reports one less.
const IQ_QUESTION_COUNT = 100;

let server;
let admin;

// The IQ handlers resolve a uuid via connectedPlayers, so a raw socket can't
// drive them -- register a build and connect as that player first, same as a
// real client would after a successful stateRequest.
async function registerPlayer() {
    const build = await distClient.deployBuild(TEST_PORT, admin, {});
    const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
    return { conn, uuid: build.uuid };
}

describe('server-side IQ countdown', () => {
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

    test('iqStartCountdown makes the server tick the countdown down at ~1 s cadence', async () => {
        const { conn } = await registerPlayer();
        try {
            conn.send({ iqStartCountdown: {} });

            const isTick = (m) => m.payload === 'iqCountdownTick';
            const t0 = Date.now();
            const first = await conn.waitFor(isTick, 3000);
            const firstAt = Date.now() - t0;
            const second = await conn.waitFor(isTick, 3000);
            const secondAt = Date.now() - t0;

            // The server owns the count: it starts at iqQuestionCount and the
            // client never supplied it.
            expect(first.iqCountdownTick.remaining).toBe(IQ_QUESTION_COUNT - 1);
            expect(second.iqCountdownTick.remaining).toBe(IQ_QUESTION_COUNT - 2);

            // Roughly one second apart (generous bounds for CI jitter).
            expect(firstAt).toBeGreaterThan(700);
            expect(firstAt).toBeLessThan(2500);
            expect(secondAt - firstAt).toBeGreaterThan(700);
            expect(secondAt - firstAt).toBeLessThan(2500);
        } finally {
            await conn.close();
        }
    }, 15000);

    test('a disconnect mid-countdown pauses it, and reconnecting + iqResume picks it back up', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {});
        const { conn: first } = await connectAsPlayer(TEST_PORT, build.uuid);

        first.send({ iqStartCountdown: {} });
        const isTick = (m) => m.payload === 'iqCountdownTick';
        const beforeDisconnect = await first.waitFor(isTick, 3000);
        const remainingAtDisconnect = beforeDisconnect.iqCountdownTick.remaining;

        // Drop the connection mid-countdown. The server pauses (bumps the timer's
        // epoch so any in-flight sleep becomes a stale no-op) rather than losing
        // dingCount/totalDings/countdownRemaining.
        await first.close();

        // Reconnect as the same uuid and resume the paused countdown.
        const { conn: second } = await connectAsPlayer(TEST_PORT, build.uuid);
        try {
            second.send({ iqResume: {} });
            const resumedTick = await second.waitFor(isTick, 3000);

            // Picked up at (about) the same remaining count it was paused at --
            // not reset to iqQuestionCount, and not still running in the
            // background while disconnected.
            expect(resumedTick.iqCountdownTick.remaining).toBeLessThanOrEqual(remainingAtDisconnect);
            expect(resumedTick.iqCountdownTick.remaining).toBeGreaterThan(remainingAtDisconnect - 3);
        } finally {
            await second.close();
        }
    }, 15000);

    test('a disconnect mid-countdown does not disturb other connected clients', async () => {
        const { conn: connA } = await registerPlayer();
        const { conn: connB } = await registerPlayer();
        try {
            connA.send({ iqStartCountdown: {} });
            connB.send({ iqStartCountdown: {} });

            const isTick = (m) => m.payload === 'iqCountdownTick';
            await connA.waitFor(isTick, 3000);
            await connB.waitFor(isTick, 3000);

            // Drop A mid-countdown; its server-side timer is paused (epoch bumped)
            // rather than removed, and B is unaffected either way.
            await connA.close();

            const nextForB = await connB.waitFor(isTick, 3000);
            expect(nextForB.iqCountdownTick.remaining).toBeLessThan(IQ_QUESTION_COUNT);
        } finally {
            await connB.close();
        }
    }, 15000);
});
