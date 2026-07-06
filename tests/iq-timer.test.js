'use strict';

// End-to-end check of the server-driven IQ-test timer: pressing "Begin"
// (iqStartCountdown) makes the server run the countdown itself and stream
// iqCountdownTick events, and a disconnect mid-countdown is cleaned up without
// disturbing other clients. The full ding/scoring/completion progression runs
// on a real 100 s countdown + 2–15 s ding gaps in production, so it is verified
// by the fast pure elm-test (tests/ServerTest.elm), not over the wire here.

const { startTestServer } = require('./helpers/testServer');
const { connect } = require('./helpers/protocolClient');

const TEST_PORT = 19471;

// Mirrors src/Game/IQTest.elm iqQuestionCount (production value); the countdown
// starts here and the first tick reports one less.
const IQ_QUESTION_COUNT = 100;

let server;

describe('server-side IQ countdown', () => {
    beforeAll(async () => {
        server = await startTestServer({ port: TEST_PORT });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('iqStartCountdown makes the server tick the countdown down at ~1 s cadence', async () => {
        const conn = await connect(TEST_PORT);
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

    test('a disconnect mid-countdown is cleaned up and does not disturb other clients', async () => {
        const a = await connect(TEST_PORT);
        const b = await connect(TEST_PORT);
        try {
            a.send({ iqStartCountdown: {} });
            b.send({ iqStartCountdown: {} });

            const isTick = (m) => m.payload === 'iqCountdownTick';
            // Both are ticking.
            await a.waitFor(isTick, 3000);
            await b.waitFor(isTick, 3000);

            // Drop A mid-countdown; its server-side timer entry is removed and its
            // pending Process.sleep fires become no-ops (epoch guard).
            await a.close();

            // B keeps receiving ticks — the server didn't crash and A's cleanup
            // didn't touch B.
            const nextForB = await b.waitFor(isTick, 3000);
            expect(nextForB.iqCountdownTick.remaining).toBeLessThan(IQ_QUESTION_COUNT);
        } finally {
            await b.close();
        }
    }, 15000);
});
