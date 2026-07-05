'use strict';

const fs = require('fs');
const path = require('path');
const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { connectAsPlayer } = require('./helpers/playerClient');
const { waitUntil } = require('./helpers/waitUntil');

const TEST_PORT = 19452;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const WIN_TEXT = 'Text "creeper... awwww man" to Max to claim your reward!';

let server;
let admin;

// Minimal player state whose screen is the win-confirming screen the client syncs right
// before revealing WinScreen (see src/Main.elm WsSyncTick / src/Server/Protocol.elm stateIsWin).
function stateWithScreen(screen) {
    return JSON.stringify({
        screen,
        jeopardyPlaying: false,
        now: 0,
        pending: [],
        savedState: null,
        dingKey: 0,
        pendingStartTime: null,
        wsClientId: null,
        timerEndsAt: 0,
    });
}

function readRegistry() {
    const file = path.join(server.tempDir, 'app-builds', 'builds.jsonl');
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
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

    test('a win-transition stateUpdate triggers a winText message with the text', async () => {
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
        const winMsg = await conn.waitFor((m) => m.payload === 'winText');
        expect(winMsg.winText.text).toBe(WIN_TEXT);
        await conn.close();
    }, 10000);

    test('a replacement build inherits the win text from the build it replaces', async () => {
        const original = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'win-orig.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === original.uuid));

        const replacement = await distClient.replaceBuild(TEST_PORT, admin, original.uuid, {
            platform: 'mac',
            filename: 'win-replacement.dmg',
        });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === replacement.uuid));
        expect(entry.winText).toBe(WIN_TEXT);
    }, 10000);

    test('a non-win stateUpdate does not trigger a winText message', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'win-nonwin.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        conn.send({ stateUpdate: { json: stateWithScreen({ tag: 'BeginScreen' }) } });
        // The ack still comes back; a winText message must not.
        await conn.waitFor((m) => m.payload === 'ack');
        await expect(conn.waitFor((m) => m.payload === 'winText', 500)).rejects.toThrow();
        await conn.close();
    }, 10000);
});
