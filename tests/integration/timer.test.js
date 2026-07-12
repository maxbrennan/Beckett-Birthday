'use strict';

const registryHelper = require('../helpers/registry');
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { connect } = require('../helpers/protocolClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19454;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
const TOLERANCE_MS = 60 * 1000;

let server;
let admin;

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
}

function writeRegistry(entries) {
    registryHelper.writeRegistry(server.tempDir, entries);
}

// The server only evicts a uuid from connectedPlayers once it processes the WS 'close'
// event for the old connection -- which can land slightly after the client's own close()
// resolves. A reconnect attempt in that window is correctly rejected as "duplicate uuid",
// so retry rather than racing it with a fixed sleep.
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

// A freshly restarted server rehydrates its registry from builds.json asynchronously
// (Server.elm's init issues a readFile port request); a stateRequest that lands before
// that read completes is rejected as "unknown uuid" and the socket closed. Retry until
// the server answers with a real state response, mirroring reconnectAsPlayer above.
async function requestStateAfterRestart(port, uuid, { timeoutMs = 5000 } = {}) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const conn = await connect(port);
        conn.send({ stateRequest: { uuid } });
        let msg = null;
        try {
            msg = await conn.waitFor(
                (m) => m.payload === 'timedOut' || m.payload === 'stateUpdate' || m.payload === 'stateRequestRejected'
            );
        } catch (err) {
            // rejectAndClose can close the socket before the rejection is observed.
        }
        if (msg && msg.payload !== 'stateRequestRejected') return { conn, result: msg };
        await conn.close();
        if (Date.now() > deadline) {
            throw new Error('requestStateAfterRestart: timed out — server still rejecting the uuid');
        }
        await new Promise((r) => setTimeout(r, 20));
    }
}

describe('server-side 7-day session timer (issue #50)', () => {
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

    test("a fresh deploy's first stateRequest establishes and persists a ~7-day deadline", async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'timer-fresh.dmg',
        });

        const before = Date.now();
        const { conn, result } = await connectAsPlayer(TEST_PORT, build.uuid);
        expect(result.payload).toBe('stateUpdate');

        const syncMsg = await conn.waitFor((m) => m.payload === 'timerSync');
        const deadline = syncMsg.timerSync.timerEndsAt;
        expect(deadline).toBeGreaterThan(before + SEVEN_DAYS_MS - TOLERANCE_MS);
        expect(deadline).toBeLessThan(Date.now() + SEVEN_DAYS_MS + TOLERANCE_MS);

        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid && e.timerEndsAt));
        expect(entry.timerEndsAt).toBe(deadline);

        await conn.close();
    }, 10000);

    test('reconnecting reuses the already-established deadline instead of recomputing it', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'timer-reconnect.dmg',
        });

        const first = await connectAsPlayer(TEST_PORT, build.uuid);
        const firstSync = await first.conn.waitFor((m) => m.payload === 'timerSync');
        await first.conn.close();

        const second = await reconnectAsPlayer(TEST_PORT, build.uuid);
        const secondSync = await second.conn.waitFor((m) => m.payload === 'timerSync');
        expect(secondSync.timerSync.timerEndsAt).toBe(firstSync.timerSync.timerEndsAt);

        await second.conn.close();
    }, 10000);

    test('a player already past their deadline gets timedOut instead of the normal state response, on connect and on sync', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'timer-expired.dmg',
        });

        // Establish a deadline, then disconnect so the server restart below finds a
        // clean connectedPlayers set.
        const { conn: setupConn } = await connectAsPlayer(TEST_PORT, build.uuid);
        await setupConn.close();

        await server.stop({ keepData: true });
        const entries = readRegistry();
        const rewritten = entries.map((e) => (e.uuid === build.uuid ? { ...e, timerEndsAt: Date.now() - 1000 } : e));
        writeRegistry(rewritten);
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });

        const { conn, result: connectMsg } = await requestStateAfterRestart(TEST_PORT, build.uuid);
        expect(connectMsg.payload).toBe('timedOut');

        // The periodic sync loop (ClientStateUpdate) independently re-checks expiry too.
        conn.send({ stateUpdate: { json: JSON.stringify({ tag: 'IQTestActiveScreen' }) } });
        const syncMsg = await conn.waitFor((m) => m.payload === 'timedOut' || m.payload === 'stateUpdateAck');
        expect(syncMsg.payload).toBe('timedOut');

        await conn.close();
    }, 15000);

    test('an expired session keeps delivering timedOut on a later reconnect too, re-derived fresh from timerEndsAt each time', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'timer-expired-reconnect.dmg',
        });

        const { conn: setupConn } = await connectAsPlayer(TEST_PORT, build.uuid);
        await setupConn.close();

        await server.stop({ keepData: true });
        const entries = readRegistry();
        const rewritten = entries.map((e) => (e.uuid === build.uuid ? { ...e, timerEndsAt: Date.now() - 1000 } : e));
        writeRegistry(rewritten);
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });

        const { conn, result: connectMsg } = await requestStateAfterRestart(TEST_PORT, build.uuid);
        expect(connectMsg.payload).toBe('timedOut');
        await conn.close();

        // Nothing is cached for this -- expiry is re-derived fresh from timerEndsAt on
        // every connect, so a second reconnect independently gets timedOut again too.
        const { conn: secondConn, result: secondConnectMsg } = await requestStateAfterRestart(TEST_PORT, build.uuid);
        expect(secondConnectMsg.payload).toBe('timedOut');
        await secondConn.close();
    }, 15000);

    test("a replacement build inherits the original build's deadline rather than starting a fresh one", async () => {
        const original = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'timer-replace-old.dmg',
        });

        const { conn } = await connectAsPlayer(TEST_PORT, original.uuid);
        const originalSync = await conn.waitFor((m) => m.payload === 'timerSync');
        await conn.close();

        const replacement = await distClient.replaceBuild(TEST_PORT, admin, original.uuid, {
            platform: 'mac',
            filename: 'timer-replace-new.dmg',
        });

        const newEntry = await waitUntil(() => readRegistry().find((e) => e.uuid === replacement.uuid));
        expect(newEntry.timerEndsAt).toBe(originalSync.timerSync.timerEndsAt);
    }, 10000);
});
