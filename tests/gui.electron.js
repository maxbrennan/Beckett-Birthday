'use strict';

// Drives the real, compiled Electron client with Playwright — the only part of the
// original test checklist that genuinely needs a rendered window and playing audio
// rather than a fake protocol-level client. Not a Jest file: Playwright's `_electron`
// launches a real subprocess and talks to it over CDP, which doesn't fit Jest's model,
// so this is a plain Node script invoked directly (see the `test:gui` npm script) and
// folded into `npm test` as its own step.
//
// Requires `npm run build` (both elm-client.js and elm-server.js) to have already run.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { _electron: electron } = require('playwright');
const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { PROJECT_ROOT } = require('./helpers/certPaths');
const globalSetup = require('./helpers/globalSetup');
const globalTeardown = require('./helpers/globalTeardown');

const TEST_PORT = 19451;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const APP_UUID_PATH = path.join(PROJECT_ROOT, 'app-uuid.json');
const AUDIO_ASSET_PATH = path.join(PROJECT_ROOT, 'assets', 'jeopardy-theme.mp3');

async function waitUntil(fn, { timeoutMs = 8000, intervalMs = 150 } = {}) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const result = await fn();
        if (result) return result;
        if (Date.now() > deadline) throw new Error('timed out waiting for condition');
        await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
}

async function readAudioState(window) {
    return window.evaluate(() => {
        const el = document.getElementById('jeopardy-audio');
        return el ? { exists: true, paused: el.paused, currentTime: el.currentTime } : { exists: false };
    });
}

async function bodyText(window) {
    return window.evaluate(() => document.body.innerText);
}

// Loading + decoding the local mp3 file takes a little while (a few seconds observed
// locally), so autoplay doesn't kick in the instant the element is inserted — poll for
// playback to actually start rather than asserting immediately, then confirm currentTime
// is really advancing (not just stuck reporting non-zero).
async function assertAudioPlaying(window) {
    const playing = await waitUntil(async () => {
        const state = await readAudioState(window);
        return state.exists && state.paused === false ? state : null;
    }, { timeoutMs: 10000 });

    await new Promise((resolve) => setTimeout(resolve, 500));
    const later = await readAudioState(window);
    assert.ok(
        later.currentTime > playing.currentTime,
        `expected #jeopardy-audio currentTime to advance (was ${playing.currentTime}, now ${later.currentTime})`
    );
}

async function main() {
    // app-uuid.json is gitignored and, without it, the client goes straight to an error
    // screen without ever attempting to connect (src/Main.elm's UuidLoaded Nothing case) —
    // the client reads it from the project root (confirmed empirically, not from client/
    // as bridge.js's readFile port's __dirname might suggest). Back up/restore rather than
    // assume it doesn't already exist, since a real local deploy could have created one.
    const hadExistingUuidFile = fs.existsSync(APP_UUID_PATH);
    const backedUpUuid = hadExistingUuidFile ? fs.readFileSync(APP_UUID_PATH, 'utf8') : null;

    // assets/ is gitignored (real media files are placed locally by whoever runs the app,
    // not committed — some are hundreds of MB) so a fresh checkout/CI runner has no
    // jeopardy-theme.mp3 at all. This test only needs to prove an audio element is really
    // playing, not that it sounds like anything — generate a short silent placeholder when
    // the real asset isn't present, the same way Tier 1 uploads dummy build bytes instead
    // of a real signed installer.
    const hadExistingAudioAsset = fs.existsSync(AUDIO_ASSET_PATH);
    if (!hadExistingAudioAsset) {
        fs.mkdirSync(path.dirname(AUDIO_ASSET_PATH), { recursive: true });
        execSync(
            `ffmpeg -y -f lavfi -i anullsrc=r=44100:cl=mono -t 5 -q:a 9 "${AUDIO_ASSET_PATH}"`,
            { stdio: 'pipe' }
        );
    }

    let server;
    let electronApp;

    // This runs outside Jest, so it needs its own copy of the self-signed test cert —
    // reusing the same idempotent setup/teardown Jest's globalSetup/globalTeardown use.
    await globalSetup();

    try {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
        const admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-gui-test.dmg',
        });

        fs.writeFileSync(APP_UUID_PATH, JSON.stringify({ uuid: build.uuid }));

        electronApp = await electron.launch({
            args: ['.'],
            cwd: PROJECT_ROOT,
            env: {
                ...process.env,
                DEV: 'false',
                PROD_SERVER_HOST: 'localhost',
                PROD_SERVER_PORT: String(TEST_PORT),
            },
        });
        const window = await electronApp.firstWindow();

        // --- render + audio: the client reaches BeginScreen with jeopardy audio playing ---
        await window.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        console.log('  ✓ Begin button rendered');

        await assertAudioPlaying(window);
        console.log('  ✓ #jeopardy-audio is actually playing (currentTime is advancing)');

        // --- stop/reconnect: disconnect shows "Connecting...", restart re-renders BeginScreen ---
        const tempDir = server.tempDir;
        await server.stop({ keepData: true });

        await waitUntil(async () => (await bodyText(window)).includes('Connecting to server...'));
        console.log('  ✓ client shows "Connecting to server..." after the server stops');

        server = await startTestServer({ port: TEST_PORT, existingTempDir: tempDir });

        await window.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await assertAudioPlaying(window);
        console.log('  ✓ client reconnects and re-renders BeginScreen with audio playing, without relaunching Electron');

        console.log('\nGUI suite passed.');
    } finally {
        if (electronApp) await electronApp.close().catch(() => {});
        if (server) await server.stop().catch(() => {});
        if (hadExistingUuidFile) fs.writeFileSync(APP_UUID_PATH, backedUpUuid);
        else fs.rmSync(APP_UUID_PATH, { force: true });
        if (!hadExistingAudioAsset) fs.rmSync(AUDIO_ASSET_PATH, { force: true });
        await globalTeardown();
    }
}

main().catch((err) => {
    console.error('\nGUI suite FAILED:', err);
    process.exitCode = 1;
});
