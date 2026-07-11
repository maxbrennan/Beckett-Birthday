'use strict';

const registryHelper = require('../helpers/registry');
const { startTestServer, TEST_QUIZ_QUESTION_COUNT } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19452;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const WIN_TEXT = 'Text "creeper... awwww man" to Max to claim your reward!';

let server;
let admin;

// Minimal player state whose screen is the win-confirming screen the client syncs right
// before revealing WinScreen (see src/Main.elm WsSyncTick / src/Server/Protocol.elm stateIsWin).
function stateWithScreen(screen) {
    return JSON.stringify({ isBeginScreen: false, screen });
}

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
}

describe('win text delivery', () => {
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

    test('deploy stores winText at top level of the registry entry, outside state', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'win-store.dmg',
            winText: WIN_TEXT,
        });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));
        expect(entry.winText).toBe(WIN_TEXT);
        // winText is a sibling of uuid, not nested inside the (still empty) state.
        expect(entry.state).toBeNull();
    });

    // Regression test for the fixed exploit (issue #33): the server used to grant
    // winText purely because the client self-reported this screen tag in a
    // freeform stateUpdate blob (see the removed src/Server/Protocol.elm
    // stateIsWin), with zero independent verification. Now winText is only ever
    // granted once the server's own tracked quiz progress (quizAdvanced events,
    // see tests/integration/quiz-progress.test.js) independently confirms
    // completion, so this same crafted stateUpdate -- sent by a player who never
    // sent a single quizAdvanced event -- must no longer produce anything.
    test('a crafted win-claiming stateUpdate, with no server-tracked quiz progress, does not trigger winText', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'win-deliver.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({
            stateUpdate: {
                json: stateWithScreen({ tag: 'ConfirmingAnswerScreen', nextScreen: { tag: 'WinScreen' } }),
            },
        });
        // The ack still comes back; a winText message must not.
        await conn.waitFor((m) => m.payload === 'stateUpdateAck');
        await expect(conn.waitFor((m) => m.payload === 'winText', 500)).rejects.toThrow();
        await conn.close();
    }, 10000);

    // winText is resent fresh on every replace deploy, not inherited from the uuid being
    // replaced (see #77 -- a deliberate divergence from state/iqTimer/quizProgress/
    // timerEndsAt, which the server does carry forward).
    test('a replacement build uses the newly-sent win text, not the original\'s', async () => {
        const original = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'win-orig.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === original.uuid));

        const REPLACEMENT_WIN_TEXT = 'Text a different code to Max to claim your reward!';
        const replacement = await distClient.replaceBuild(TEST_PORT, admin, original.uuid, {
            platform: 'mac',
            filename: 'win-replacement.dmg',
            winText: REPLACEMENT_WIN_TEXT,
        });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === replacement.uuid));
        expect(entry.winText).toBe(REPLACEMENT_WIN_TEXT);
    }, 10000);

    test('a non-win stateUpdate does not trigger a winText message', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'win-nonwin.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ stateUpdate: { json: stateWithScreen({ tag: 'BlankScreen', idx: 0 }) } });
        // The ack still comes back; a winText message must not.
        await conn.waitFor((m) => m.payload === 'stateUpdateAck');
        await expect(conn.waitFor((m) => m.payload === 'winText', 500)).rejects.toThrow();
        await conn.close();
    }, 10000);

    // Once WinScreen is derivable (see Server.elm's deriveWinScreen), a player who
    // reconnects after already completing the quiz -- whether they closed the app right
    // at the moment they won, before ever seeing the reveal, or reconnect much later --
    // gets a bare derived WinScreen with no text. The reconnect must re-send winText
    // alongside it rather than leaving the reveal blank forever.
    test('reconnecting after a win re-delivers winText, even though the derived screen carries no text', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'win-reconnect.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        for (let idx = 0; idx < TEST_QUIZ_QUESTION_COUNT; idx += 1) {
            conn.send({ quizAdvanced: { idx } });
        }
        await conn.waitFor((m) => m.payload === 'winText');
        await conn.close();

        const { conn: reconn, result } = await connectAsPlayer(TEST_PORT, build.uuid);
        const delivered = JSON.parse(result.stateUpdate.json);
        expect(delivered.screen.tag).toBe('WinScreen');
        const winTextMsg = await reconn.waitFor((m) => m.payload === 'winText');
        expect(winTextMsg.winText.text).toBe(WIN_TEXT);
        await reconn.close();
    }, 10000);
});
