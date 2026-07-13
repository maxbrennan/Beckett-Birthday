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
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const registryHelper = require('../helpers/registry');
const { PROJECT_ROOT } = require('../helpers/certPaths');
const globalSetup = require('../helpers/globalSetup');
const globalTeardown = require('../helpers/globalTeardown');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19451;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const APP_UUID_PATH = path.join(PROJECT_ROOT, 'app-uuid.json');
const AUDIO_ASSET_PATH = path.join(PROJECT_ROOT, 'assets', 'jeopardy-theme.mp3');
const GUI_WAIT_OPTS = { timeoutMs: 8000, intervalMs: 150 };

async function readAudioState(window) {
    return window.evaluate(() => {
        const el = document.getElementById('jeopardy-audio');
        return el ? { exists: true, paused: el.paused, currentTime: el.currentTime } : { exists: false };
    });
}

async function bodyText(window) {
    return window.evaluate(() => document.body.innerText);
}

async function waitForBodyTextIncluding(window, substring, opts = GUI_WAIT_OPTS) {
    await waitUntil(async () => (await bodyText(window)).includes(substring) ? true : null, opts);
}

// Fast-forwards a build straight to a live, real-dings-already-cleared IQ timer via
// the admin edit:state path -- the same technique tests/integration/iq-offer.test.js
// uses at the protocol level, needed here too since actually waiting through
// iqQuestionCount real dings (each gated by a 2-15s random production delay) would
// make this scenario impractically slow. `IqAwaitingReady`/`IqDingScheduled` both
// derive to IQTestActiveScreen with every flash/ding flag false (see
// Server.elm's deriveIqScreen), so the real client renders an idle "waiting for the
// next ding" screen -- pressing Space there is a genuine SpaceBarFailed via the
// real Game.IQTest.decideSpaceBar, not a simulated one.
async function stageQualifyingIqOffer(server, admin, port, uuid) {
    const { authResult, conn, json } = await distClient.requestStateEdit(port, admin, uuid);
    if (!authResult.success) throw new Error('admin auth failed while staging iqTimer');
    const fetched = JSON.parse(json);
    const edited = {
        ...fetched,
        iqTimer: {
            epoch: 1,
            phase: 'IqAwaitingReady',
            questionIdx: 0,
            countdownRemaining: 0,
            dingCount: 10,
            totalDings: 100,
            fakeFlashPoint: 9999,
            fakeFlashUsed: false,
            in50PercentPhase: false,
            lastDing: 'RealDing',
            dingDelay: null,
        },
    };
    const resultMsg = await distClient.saveStateEdit(conn, uuid, JSON.stringify(edited));
    if (resultMsg.payload !== 'distStateEditSaveAck') throw new Error(`stageQualifyingIqOffer save failed: ${resultMsg.payload}`);
    await conn.close();
    await waitUntil(() => {
        const found = registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === uuid);
        return found && found.iqTimer && found.iqTimer.phase === 'IqAwaitingReady' ? found : null;
    });
}

// Loading + decoding the local mp3 file takes a little while (a few seconds observed
// locally), so autoplay doesn't kick in the instant the element is inserted — poll for
// playback to actually start rather than asserting immediately, then confirm currentTime
// is really advancing (not just stuck reporting non-zero).
async function assertAudioPlaying(window) {
    const playing = await waitUntil(async () => {
        const state = await readAudioState(window);
        return state.exists && state.paused === false ? state : null;
    }, { timeoutMs: 10000, intervalMs: GUI_WAIT_OPTS.intervalMs });

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

        await waitUntil(async () => (await bodyText(window)).includes('Connecting to server...'), GUI_WAIT_OPTS);
        console.log('  ✓ client shows "Connecting to server..." after the server stops');

        // Regression guard for #51: while the server stays down, the client should hold a
        // stable "Connecting..." message rather than flash through the error screen (an
        // unthrottled reconnect-retry loop previously caused rapid cycling between
        // "Connecting...", "Loading...", and this error message before the server came back).
        const flapCheckDeadline = Date.now() + 2000;
        while (Date.now() < flapCheckDeadline) {
            const text = await bodyText(window);
            if (text.includes('Something is wrong with the internet connection')) {
                throw new Error('client flashed the error screen while the server was cleanly stopped (issue #51 regression)');
            }
            await new Promise((resolve) => setTimeout(resolve, 150));
        }
        console.log('  ✓ client holds a stable "Connecting..." message without flashing the error screen');

        server = await startTestServer({ port: TEST_PORT, existingTempDir: tempDir });

        await window.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await assertAudioPlaying(window);
        console.log('  ✓ client reconnects and re-renders BeginScreen with audio playing, without relaunching Electron');

        // --- IQ-test skip offer: real View.elm rendering of both new screens, driven by
        // an actual SpaceBarFailed through the real Elm runtime (see stageQualifyingIqOffer
        // above for why the dings themselves are fast-forwarded rather than awaited live).
        // Each path needs its own uuid (the offer is granted at most once per build) and
        // its own Electron launch (the client only reads app-uuid.json at startup).
        await electronApp.close().catch(() => {});
        electronApp = null;

        const acceptBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-accept-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === acceptBuild.uuid));
        await stageQualifyingIqOffer(server, admin, TEST_PORT, acceptBuild.uuid);

        fs.writeFileSync(APP_UUID_PATH, JSON.stringify({ uuid: acceptBuild.uuid }));
        electronApp = await electron.launch({
            args: ['.'],
            cwd: PROJECT_ROOT,
            env: { ...process.env, DEV: 'false', PROD_SERVER_HOST: 'localhost', PROD_SERVER_PORT: String(TEST_PORT) },
        });
        let iqWindow = await electronApp.firstWindow();

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '10 / 100', GUI_WAIT_OPTS);
        console.log('  ✓ IQTestActiveScreen renders the staged, already-qualifying ding count');

        await iqWindow.keyboard.press('Space');
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', GUI_WAIT_OPTS);
        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 8000 });
        console.log('  ✓ a real SpaceBarFailed (no ding active) grants the offer but lands on the instructions screen first (issue #93)');

        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await iqWindow.getByRole('button', { name: 'Accept' }).waitFor({ state: 'visible', timeout: 8000 });
        await iqWindow.getByRole('button', { name: 'Decline' }).waitFor({ state: 'visible', timeout: 1000 });
        console.log('  ✓ pressing Begin again reveals the pending skip offer (IQTestSkipOfferScreen)');

        await iqWindow.getByRole('button', { name: 'Accept' }).click();
        await waitForBodyTextIncluding(iqWindow, 'Listen carefully...', { timeoutMs: 8000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ Accept runs the real skip animation through to the quiz (IQTestSkipAnimScreen -> BlankScreen)');

        await electronApp.close().catch(() => {});
        electronApp = null;

        const declineBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-decline-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === declineBuild.uuid));
        await stageQualifyingIqOffer(server, admin, TEST_PORT, declineBuild.uuid);

        fs.writeFileSync(APP_UUID_PATH, JSON.stringify({ uuid: declineBuild.uuid }));
        electronApp = await electron.launch({
            args: ['.'],
            cwd: PROJECT_ROOT,
            env: { ...process.env, DEV: 'false', PROD_SERVER_HOST: 'localhost', PROD_SERVER_PORT: String(TEST_PORT) },
        });
        iqWindow = await electronApp.firstWindow();

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '10 / 100', GUI_WAIT_OPTS);

        await iqWindow.keyboard.press('Space');
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', GUI_WAIT_OPTS);
        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 8000 });

        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await iqWindow.getByRole('button', { name: 'Decline' }).waitFor({ state: 'visible', timeout: 8000 });

        await iqWindow.getByRole('button', { name: 'Decline' }).click();
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', GUI_WAIT_OPTS);
        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 8000 });
        console.log('  ✓ Decline returns to the real IQTestScreen (offer releases, no skip)');

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
