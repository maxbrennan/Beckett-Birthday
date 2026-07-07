'use strict';

// Reproduces and verifies the fix for the restart-data-loss gap: the server's
// authoritative IQ timer (src/Server.elm's iqTimers) used to live purely in memory,
// so a real process restart silently reset a mid-punishment-phase player back to the
// baseline iqQuestionCount, discarding real progress. Now every live IqTimerState
// change is also mirrored into the player's registry row (RegistryEntry.iqTimer,
// builds.jsonl), and the server rehydrates iqTimers from it on startup (see
// Server.elm's init/FileRead) -- so a restart looks, to the existing pause/resume
// machinery, just like every connected player having disconnected simultaneously.

const fs = require('fs');
const path = require('path');
const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { connectAsPlayer } = require('./helpers/playerClient');

const TEST_PORT = 19473;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const IQ_QUESTION_COUNT = 100;

let server;
let admin;

async function registerPlayer() {
    const build = await distClient.deployBuild(TEST_PORT, admin, {});
    const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
    return { conn, uuid: build.uuid };
}

function registryFile() {
    return path.join(server.tempDir, 'app-builds', 'builds.jsonl');
}

function readRegistryLines() {
    return fs
        .readFileSync(registryFile(), 'utf8')
        .trim()
        .split('\n')
        .filter(Boolean)
        .map((line) => JSON.parse(line));
}

function writeRegistryLines(entries) {
    fs.writeFileSync(registryFile(), entries.map((e) => JSON.stringify(e)).join('\n') + '\n');
}

describe('IQ timer survives a server restart', () => {
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

    test('a mid-countdown restart resumes near where it left off, not reset to iqQuestionCount', async () => {
        const { conn, uuid } = await registerPlayer();

        conn.send({ iqStartCountdown: {} });
        const isTick = (m) => m.payload === 'iqCountdownTick';
        const beforeRestart = await conn.waitFor(isTick, 3000);
        const remainingAtRestart = beforeRestart.iqCountdownTick.remaining;

        // Restart the whole process against the same temp dir (same builds.jsonl).
        await server.stop({ keepData: true });
        await conn.closed();
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });

        const { conn: reconnected } = await connectAsPlayer(TEST_PORT, uuid);
        try {
            reconnected.send({ iqResume: {} });
            const resumedTick = await reconnected.waitFor(isTick, 3000);

            // Resumed near the pre-restart value -- not reset to the baseline, and
            // not still counting down somewhere in the background. The gap allows
            // for however long the process restart itself actually took.
            expect(resumedTick.iqCountdownTick.remaining).toBeLessThanOrEqual(remainingAtRestart);
            expect(resumedTick.iqCountdownTick.remaining).toBeGreaterThan(remainingAtRestart - 10);
            expect(resumedTick.iqCountdownTick.remaining).toBeLessThan(IQ_QUESTION_COUNT - 1);
        } finally {
            await reconnected.close();
        }
    }, 20000);

    test('a doubled totalDings (post-catch) survives a restart -- the next countdown uses the doubled base, not the baseline', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {});
        const uuid = build.uuid;

        // Hand-inject a server-internal IqTimerState snapshot directly into the
        // registry file (as encodeIqTimerStateFull would produce it), as if a live
        // game had reached exactly this point -- an outstanding one-time trap ding,
        // nothing caught yet -- then restart. This deterministically exercises
        // rehydrating and resuming an outstanding ding without depending on the
        // random 2-15s ding delay or fakeFlashPoint draw a live playthrough would need.
        await server.stop({ keepData: true });
        const entries = readRegistryLines();
        const idx = entries.findIndex((e) => e.uuid === uuid);
        entries[idx].iqTimer = {
            epoch: 1,
            phase: 'IqDingShown',
            questionIdx: 0,
            countdownRemaining: 0,
            dingCount: 0,
            totalDings: 100,
            fakeFlashPoint: 0,
            fakeFlashUsed: false,
            in50PercentPhase: false,
            lastDing: 'TrapFake',
        };
        writeRegistryLines(entries);
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });

        const { conn } = await connectAsPlayer(TEST_PORT, uuid);
        conn.send({ iqResume: {} });
        const ding = await conn.waitFor((m) => m.payload === 'iqDing', 3000);
        expect(ding.iqDing.trap).toBe(true);
        expect(ding.iqDing.fake).toBe(true);

        conn.send({ iqCaught: {} });
        // Give the write-through a moment to land before restarting.
        await new Promise((r) => setTimeout(r, 200));
        await conn.close();

        await server.stop({ keepData: true });
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });

        const { conn: reconnected } = await connectAsPlayer(TEST_PORT, uuid);
        try {
            reconnected.send({ iqStartCountdown: {} });
            const tick = await reconnected.waitFor((m) => m.payload === 'iqCountdownTick', 3000);
            // The doubled total (200) survived the restart -- not reset to the baseline 100.
            expect(tick.iqCountdownTick.remaining).toBe(199);
        } finally {
            await reconnected.close();
        }
    }, 20000);

    test('a non-IQ screen is unaffected by a restart, as before this change', async () => {
        const { conn, uuid } = await registerPlayer();

        const midGameState = {
            screen: { tag: 'QuestionScreen', idx: 3 },
            pending: [],
            now: 1234,
            jeopardyPlaying: false,
            savedState: null,
        };
        conn.send({ stateUpdate: { json: JSON.stringify(midGameState) } });
        await conn.waitFor((m) => m.payload === 'ack');
        await conn.close();

        await server.stop({ keepData: true });
        server = await startTestServer({ port: TEST_PORT, existingTempDir: server.tempDir });

        const { result } = await connectAsPlayer(TEST_PORT, uuid);
        expect(result.payload).toBe('stateUpdate');
        const delivered = JSON.parse(result.stateUpdate.json);
        // Left mid-game, so the lazy jeopardy snapshot kicks in on this stateRequest --
        // same as any other non-IQ screen, untouched by the IQ persistence change.
        expect(delivered.screen.tag).toBe('BeginScreen');
        expect(delivered.savedState.screen.tag).toBe('QuestionScreen');
        expect(delivered.savedState.screen.idx).toBe(3);
    }, 20000);
});
