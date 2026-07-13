'use strict';

const registryHelper = require('../helpers/registry');
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19459;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
}

// Fast-forwards a build straight to a live IqDingShown iqTimer, bypassing the real
// countdown/random-delay timers (see Server.elm's IqTimerState) via the admin
// edit:state path. Note: performStateEdit closes any currently-connected player for
// this uuid as soon as the edit starts (see Server.elm's closeClient call there) --
// so this must run *before* connectAsPlayer, not against an already-open player conn.
async function stageIqTimer(uuid, { dingCount, totalDings, lastDing = 'RealDing' }) {
    const { authResult, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, uuid);
    if (!authResult.success) throw new Error('admin auth failed while staging iqTimer');
    const fetched = JSON.parse(json);
    const edited = {
        ...fetched,
        iqTimer: {
            epoch: 1,
            phase: 'IqDingShown',
            questionIdx: 0,
            countdownRemaining: 0,
            dingCount,
            totalDings,
            fakeFlashPoint: 9999,
            fakeFlashUsed: false,
            in50PercentPhase: false,
            lastDing,
            dingDelay: null,
        },
    };
    const resultMsg = await distClient.saveStateEdit(conn, uuid, JSON.stringify(edited));
    if (resultMsg.payload !== 'distStateEditSaveAck') throw new Error(`stageIqTimer save failed: ${resultMsg.payload}`);
    await conn.close();
    await waitUntil(() => {
        const found = readRegistry().find((e) => e.uuid === uuid);
        return found && found.iqTimer && found.iqTimer.phase === 'IqDingShown' ? found : null;
    });
}

// The server only evicts a uuid from connectedPlayers once it processes the WS 'close'
// event for the old connection, which can land slightly after this test's own close()
// resolves (same race documented in song-ended.test.js's reconnectAsPlayer). stageIqTimer
// never opens a player connection itself, but the admin edit's own closeClient (for
// whatever was connected before) can still be mid-flight the first time -- retry rather
// than racing it with a fixed sleep.
async function connectAsPlayerRetrying(uuid, { timeoutMs = 2000 } = {}) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const attempt = await connectAsPlayer(TEST_PORT, uuid);
        if (attempt.result.payload === 'stateUpdate') return attempt;
        await attempt.conn.close();
        if (Date.now() > deadline) throw new Error('connectAsPlayerRetrying: timed out');
        await new Promise((r) => setTimeout(r, 20));
    }
}

// The IQ-test skip offer: the first time a player fails (or falls into the fake-flash
// trap) after clearing >= iqOfferMinDings (5) real dings, the server grants a one-time
// offer to skip the test -- see Server.elm's decideIqOffer / Model.iqOfferGrants. This
// closes the same class of client-trust gap song-ended.test.js closes for TrackEnded:
// the server, not the client, decides and durably remembers whether the offer was ever
// granted (RegistryEntry.iqOfferUsed).
describe('IQ-test one-time skip offer', () => {
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

    test('a qualifying fail (>= 5 dings cleared) grants the offer and marks it used', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: 'iq-offer-grant.dmg' });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        await stageIqTimer(build.uuid, { dingCount: 10, totalDings: 100 });
        const { conn } = await connectAsPlayerRetrying(build.uuid);

        conn.send({ iqFailed: {} });
        const decision = await conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(decision.iqOfferDecision.granted).toBe(true);
        expect(decision.iqOfferDecision.totalDings).toBe(100);

        const entry = await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === build.uuid);
            return found && found.iqOfferUsed ? found : null;
        });
        expect(entry.iqOfferUsed).toBe(true);

        await conn.close();
    }, 10000);

    test('a second fail on the same uuid is denied -- the offer is only ever granted once', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: 'iq-offer-once.dmg' });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        await stageIqTimer(build.uuid, { dingCount: 10, totalDings: 100 });
        const first = await connectAsPlayerRetrying(build.uuid);
        first.conn.send({ iqFailed: {} });
        const firstDecision = await first.conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(firstDecision.iqOfferDecision.granted).toBe(true);
        await first.conn.close();

        await stageIqTimer(build.uuid, { dingCount: 10, totalDings: 100 });
        const second = await connectAsPlayerRetrying(build.uuid);
        second.conn.send({ iqFailed: {} });
        const secondDecision = await second.conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(secondDecision.iqOfferDecision.granted).toBe(false);
        await second.conn.close();
    }, 10000);

    test('a fail below the ding threshold is denied and leaves the offer available for later', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: 'iq-offer-threshold.dmg' });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        await stageIqTimer(build.uuid, { dingCount: 4, totalDings: 100 });
        const { conn } = await connectAsPlayerRetrying(build.uuid);

        conn.send({ iqFailed: {} });
        const decision = await conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(decision.iqOfferDecision.granted).toBe(false);

        const entry = readRegistry().find((e) => e.uuid === build.uuid);
        expect(entry.iqOfferUsed).toBe(false);

        await conn.close();
    }, 10000);

    test('a build deployed with the offer disabled denies even a qualifying fail', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-disabled.dmg',
            iqSkipOfferDisabled: true,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));
        expect(readRegistry().find((e) => e.uuid === build.uuid).iqOfferDisabled).toBe(true);

        await stageIqTimer(build.uuid, { dingCount: 10, totalDings: 100 });
        const { conn } = await connectAsPlayerRetrying(build.uuid);

        conn.send({ iqFailed: {} });
        const decision = await conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(decision.iqOfferDecision.granted).toBe(false);

        await conn.close();
    }, 10000);

    test('a fake-flash trap catch grants the offer with the doubled totalDings', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: 'iq-offer-catch.dmg' });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        await stageIqTimer(build.uuid, { dingCount: 10, totalDings: 100, lastDing: 'TrapFake' });
        const { conn } = await connectAsPlayerRetrying(build.uuid);

        conn.send({ iqCaught: {} });
        const decision = await conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(decision.iqOfferDecision.granted).toBe(true);
        expect(decision.iqOfferDecision.totalDings).toBe(200);

        await conn.close();
    }, 10000);

    test('a stray iqStartCountdown sent right after a grant is silently ignored, and iqOfferDeclined releases it', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: 'iq-offer-guard.dmg' });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        await stageIqTimer(build.uuid, { dingCount: 10, totalDings: 100 });
        const { conn } = await connectAsPlayerRetrying(build.uuid);

        conn.send({ iqFailed: {} });
        const decision = await conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(decision.iqOfferDecision.granted).toBe(true);

        // Blocked: the grant is still outstanding, so this must not restart a countdown.
        conn.send({ iqStartCountdown: {} });
        await expect(conn.waitFor((m) => m.payload === 'iqCountdownTick' || m.payload === 'iqCountdownComplete', 500)).rejects.toThrow();

        // Declining releases the grant, so the next iqStartCountdown succeeds normally.
        conn.send({ iqOfferDeclined: {} });
        conn.send({ iqStartCountdown: {} });
        const entry = await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === build.uuid);
            return found && found.iqTimer && found.iqTimer.phase === 'IqCounting' ? found : null;
        });
        expect(entry.iqTimer.phase).toBe('IqCounting');

        await conn.close();
    }, 10000);

    test('accepting the offer (quizAdvanced matching the grant) bypasses the live IQ-timer block', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: 'iq-offer-accept.dmg' });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        await stageIqTimer(build.uuid, { dingCount: 10, totalDings: 100 });
        const { conn } = await connectAsPlayerRetrying(build.uuid);

        conn.send({ iqFailed: {} });
        const decision = await conn.waitFor((m) => m.payload === 'iqOfferDecision');
        expect(decision.iqOfferDecision.granted).toBe(true);

        // The offer was granted for questionIdx 0 (stageIqTimer's default) -- the real
        // client's Accept flow reports quizAdvanced for that same idx.
        conn.send({ quizAdvanced: { idx: 0 } });
        await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === build.uuid);
            return found && found.quizProgress === 1 ? found : null;
        });

        // The bypass also cleared the now-irrelevant iqTimer entry as a side effect.
        const entry = readRegistry().find((e) => e.uuid === build.uuid);
        expect(entry.iqTimer).toBeFalsy();

        await conn.close();
    }, 10000);

    test('an unrelated live IQ timer (no grant at all) still blocks quizAdvanced -- regression guard', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: 'iq-offer-noregress.dmg' });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        await stageIqTimer(build.uuid, { dingCount: 2, totalDings: 100 });
        const { conn } = await connectAsPlayerRetrying(build.uuid);

        conn.send({ quizAdvanced: { idx: 0 } });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));
        expect(entry.quizProgress).toBe(0);

        await conn.close();
    }, 10000);
});
