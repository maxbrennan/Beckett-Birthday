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
const LOUD_VIDEO_ASSET_PATH = path.join(PROJECT_ROOT, 'assets', 'loud.mp4');
// Quiz slide 0's song -- assets/songs/ files are named numerically (see
// Game.Quiz.songOrder), so "0.mp3" is the song for question index 0. A short
// (3s) placeholder keeps the #90 scenarios below fast without waiting through
// a real song's full length.
const QUIZ_SONG_ASSET_PATH = path.join(PROJECT_ROOT, 'assets', 'songs', '0.mp3');
const GUI_WAIT_OPTS = { timeoutMs: 8000, intervalMs: 150 };

async function readAudioState(window, elementId = 'jeopardy-audio') {
    return window.evaluate((id) => {
        const el = document.getElementById(id);
        return el ? { exists: true, paused: el.paused, currentTime: el.currentTime } : { exists: false };
    }, elementId);
}

async function bodyText(window) {
    return window.evaluate(() => document.body.innerText);
}

async function waitForBodyTextIncluding(window, substring, opts = GUI_WAIT_OPTS) {
    await waitUntil(async () => (await bodyText(window)).includes(substring) ? true : null, opts);
}

// Fast-forwards a build straight to a live IQ timer via the admin edit:state path --
// the same technique tests/integration/iq-offer.test.js uses at the protocol level,
// needed here too since actually waiting through iqQuestionCount real dings (each
// gated by a 2-15s random production delay) would make these scenarios impractically
// slow. `overrides` is merged onto the default (qualifying, IqAwaitingReady) iqTimer
// shape -- e.g. a lower dingCount to stay below IQTest.iqOfferMinDings, or
// `phase: 'IqDingShown'` to stage a real ding actively showing. `IqAwaitingReady`
// derives to IQTestActiveScreen with every flash/ding flag false (see
// Server.elm's deriveIqScreen), so the real client renders an idle "waiting for the
// next ding" screen -- pressing Space there is a genuine SpaceBarFailed via the real
// Game.IQTest.decideSpaceBar, not a simulated one.
async function stageIqTimer(server, admin, port, uuid, overrides = {}) {
    const { authResult, conn, json } = await distClient.requestStateEdit(port, admin, uuid);
    if (!authResult.success) throw new Error('admin auth failed while staging iqTimer');
    const fetched = JSON.parse(json);
    const iqTimer = {
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
        ...overrides,
    };
    const edited = { ...fetched, iqTimer };
    const resultMsg = await distClient.saveStateEdit(conn, uuid, JSON.stringify(edited));
    if (resultMsg.payload !== 'distStateEditSaveAck') throw new Error(`stageIqTimer save failed: ${resultMsg.payload}`);
    await conn.close();
    await waitUntil(() => {
        const found = registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === uuid);
        return found && found.iqTimer && found.iqTimer.phase === iqTimer.phase ? found : null;
    });
}

// Regression coverage for issue #92: stages a countdown (as edit:state would) already
// at/above the loud-video threshold, so the countdown-complete -> IQTestActiveScreen
// transition is the one under test, not the IqAwaitingReady/IqDingShown derive path
// stageIqTimer above exercises. countdownRemaining is 1 (ticks are a real 1000ms each
// -- see Server.elm's scheduleCountdownStep) purely to keep the test fast.
async function stageCountdownAtLoudThreshold(server, admin, port, uuid, dingCount) {
    const { authResult, conn, json } = await distClient.requestStateEdit(port, admin, uuid);
    if (!authResult.success) throw new Error('admin auth failed while staging iqTimer');
    const fetched = JSON.parse(json);
    const edited = {
        ...fetched,
        iqTimer: {
            epoch: 1,
            phase: 'IqCounting',
            questionIdx: 0,
            countdownRemaining: 1,
            dingCount,
            totalDings: 100,
            fakeFlashPoint: 9999,
            fakeFlashUsed: false,
            in50PercentPhase: false,
            lastDing: 'RealDing',
            dingDelay: null,
        },
    };
    const resultMsg = await distClient.saveStateEdit(conn, uuid, JSON.stringify(edited));
    if (resultMsg.payload !== 'distStateEditSaveAck') throw new Error(`stageCountdownAtLoudThreshold save failed: ${resultMsg.payload}`);
    await conn.close();
    await waitUntil(() => {
        const found = registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === uuid);
        return found && found.iqTimer && found.iqTimer.phase === 'IqCounting' ? found : null;
    });
}

async function readVideoState(window) {
    return window.evaluate(() => {
        const el = document.getElementById('playing-video');
        return el ? { exists: true, paused: el.paused } : { exists: false, paused: null };
    });
}

// FakeFlashCaughtScreen (View.elm) renders both cutscene captions unconditionally --
// only their inline opacity toggles per FakeFlashPhase -- so plain bodyText can't tell
// "on the screen at all" (true from FfDelay onward) apart from "actually mid-animation"
// (true only once a phase actually sets opacity to 1). Reading the real inline style is
// the only way to observe the local FakeFlashNextPhase schedule actually progressing,
// which is exactly what issue #104's fix re-arms on resume.
async function fakeFlashCaptionVisible(window, captionText) {
    return window.evaluate((txt) => {
        const p = Array.from(document.querySelectorAll('p')).find((el) => el.textContent === txt);
        return !!p && p.style.opacity === '1';
    }, captionText);
}

const FAKE_FLASH_CAPTION_1 = 'You pressed the space bar because you saw a green flash.';

// Loading + decoding the local mp3 file takes a little while (a few seconds observed
// locally), so autoplay doesn't kick in the instant the element is inserted — poll for
// playback to actually start rather than asserting immediately, then confirm currentTime
// is really advancing (not just stuck reporting non-zero).
async function assertAudioPlaying(window, elementId = 'jeopardy-audio') {
    const playing = await waitUntil(async () => {
        const state = await readAudioState(window, elementId);
        return state.exists && state.paused === false ? state : null;
    }, { timeoutMs: 10000, intervalMs: GUI_WAIT_OPTS.intervalMs });

    await new Promise((resolve) => setTimeout(resolve, 500));
    const later = await readAudioState(window, elementId);
    assert.ok(
        later.currentTime > playing.currentTime,
        `expected #${elementId} currentTime to advance (was ${playing.currentTime}, now ${later.currentTime})`
    );
}

// Fetches a build's current edit:state document and saves it straight back
// unchanged -- the "admin opens vim, makes no edits, quits" step of the edit:state
// flow, as opposed to stageIqTimer's override-and-save. Used to reproduce issue
// #52 against a *live, currently-connected* player: unlike stageIqTimer's callers
// (which always stage before a client connects), this is invoked while a real
// client window is already open, so the closeClient kick this triggers races the
// real disconnect-driven rewind the same way the real admin tool does.
async function resaveIqTimerUnchanged(admin, port, uuid) {
    const { authResult, conn, json } = await distClient.requestStateEdit(port, admin, uuid);
    if (!authResult.success) throw new Error('admin auth failed while resaving iqTimer unchanged');
    const resultMsg = await distClient.saveStateEdit(conn, uuid, json);
    if (resultMsg.payload !== 'distStateEditSaveAck') throw new Error(`resaveIqTimerUnchanged save failed: ${resultMsg.payload}`);
    await conn.close();
    return JSON.parse(json);
}

// Points app-uuid.json at uuid and launches a fresh Electron process reading it --
// the client only reads this file at startup, so this is the "close and reopen the
// client" step the reconnect scenarios below need, not just a websocket reconnect
// within the same window.
async function launchClientFor(uuid) {
    fs.writeFileSync(APP_UUID_PATH, JSON.stringify({ uuid }));
    const electronApp = await electron.launch({
        args: ['.'],
        cwd: PROJECT_ROOT,
        env: { ...process.env, DEV: 'false', PROD_SERVER_HOST: 'localhost', PROD_SERVER_PORT: String(TEST_PORT) },
    });
    return { electronApp, window: await electronApp.firstWindow() };
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

    // Same placeholder rationale as the audio asset above -- assets/loud.mp4 is
    // gitignored, so a fresh checkout/CI runner needs a stand-in to actually assert
    // playback against (see stageCountdownAtLoudThreshold's regression test).
    const hadExistingVideoAsset = fs.existsSync(LOUD_VIDEO_ASSET_PATH);
    if (!hadExistingVideoAsset) {
        fs.mkdirSync(path.dirname(LOUD_VIDEO_ASSET_PATH), { recursive: true });
        execSync(
            `ffmpeg -y -f lavfi -i color=c=black:s=64x64:d=5 -f lavfi -i anullsrc=r=44100:cl=mono -shortest -pix_fmt yuv420p "${LOUD_VIDEO_ASSET_PATH}"`,
            { stdio: 'pipe' }
        );
    }

    // Same placeholder-generation trick, for quiz slide 0's song (see the #90
    // scenarios below) -- 3s keeps a real, genuine TrackEnded fast to wait for.
    const hadExistingQuizSongAsset = fs.existsSync(QUIZ_SONG_ASSET_PATH);
    if (!hadExistingQuizSongAsset) {
        fs.mkdirSync(path.dirname(QUIZ_SONG_ASSET_PATH), { recursive: true });
        execSync(
            `ffmpeg -y -f lavfi -i anullsrc=r=44100:cl=mono -t 3 -q:a 9 "${QUIZ_SONG_ASSET_PATH}"`,
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
        // an actual SpaceBarFailed through the real Elm runtime (see stageIqTimer above
        // for why the dings themselves are fast-forwarded rather than awaited live).
        // Each path needs its own uuid (the offer is granted at most once per build) and
        // its own Electron launch (the client only reads app-uuid.json at startup).
        await electronApp.close().catch(() => {});
        electronApp = null;

        const acceptBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-accept-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === acceptBuild.uuid));
        await stageIqTimer(server, admin, TEST_PORT, acceptBuild.uuid);

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
        // The count-up animation now genuinely ticks displayCount from 0 to totalDings
        // (100 here) at counterTickMs (80ms) per step -- ~8s of ticking alone, plus the
        // surrounding phase delays -- so this needs real headroom, not the old ~8s
        // budget that only worked because of the jump-straight-to-total bug (#94).
        await waitForBodyTextIncluding(iqWindow, 'Listen carefully...', { timeoutMs: 16000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ Accept runs the real skip animation through to the quiz (IQTestSkipAnimScreen -> BlankScreen)');

        await electronApp.close().catch(() => {});
        electronApp = null;

        const declineBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-decline-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === declineBuild.uuid));
        await stageIqTimer(server, admin, TEST_PORT, declineBuild.uuid);

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

        await electronApp.close().catch(() => {});
        electronApp = null;

        // --- issue #92 regression: a countdown staged (via edit:state) already at/above
        // the loud-video threshold must render the real dingCount immediately on
        // countdown-complete, and must still start the loud video a few seconds later,
        // rather than never triggering it (the old code only ever fired on the exact
        // dingCount 3->4 transition, which a pre-staged count skips past entirely).
        const loudBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-loud-threshold-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === loudBuild.uuid));
        await stageCountdownAtLoudThreshold(server, admin, TEST_PORT, loudBuild.uuid, 5);

        fs.writeFileSync(APP_UUID_PATH, JSON.stringify({ uuid: loudBuild.uuid }));
        electronApp = await electron.launch({
            args: ['.'],
            cwd: PROJECT_ROOT,
            env: { ...process.env, DEV: 'false', PROD_SERVER_HOST: 'localhost', PROD_SERVER_PORT: String(TEST_PORT) },
        });
        const loudWindow = await electronApp.firstWindow();

        // Every derived screen arrives wrapped in BeginScreen (see Server.elm's
        // ClientConnected handler) -- pressing Begin unwraps it locally with no round
        // trip (Main.elm's BeginPressed), which is what actually puts the client on
        // IQTestCountdownScreen and makes it fire iqResumeEnvelope (re-arming the
        // dormant countdown -- see Server.elm's resumeIqTimer).
        await loudWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await loudWindow.getByRole('button', { name: 'Begin' }).click();

        await waitForBodyTextIncluding(loudWindow, '5 / 100', { timeoutMs: 8000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ countdown-complete renders the staged dingCount immediately (no 0/100 glitch)');

        const soonAfter = await readVideoState(loudWindow);
        assert.ok(!soonAfter.exists || soonAfter.paused, 'expected the loud video not to be playing yet, right after the countdown completed');
        console.log('  ✓ loud video is not playing immediately after countdown-complete');

        await waitUntil(async () => {
            const state = await readVideoState(loudWindow);
            return state.exists && state.paused === false ? state : null;
        }, { timeoutMs: 8000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ loud video starts playing a few seconds later');

        // --- issue #88 regression: a fail below the skip-offer threshold must leave the
        // player able to close and reopen the client and land back on the IQ instructions
        // screen, not the frozen live/dinging screen (the freeze the issue described was
        // pre-#91's iqFail sending no server message at all, so the server's iqTimer never
        // left its live phase). dingCount: 2 is below IQTest.iqOfferMinDings (5), so the
        // fail is deliberately non-qualifying and must land on plain IQTestScreen, not
        // IQTestSkipOfferScreen (unlike the accept/decline scenarios above).
        await electronApp.close().catch(() => {});
        electronApp = null;

        const spaceFailBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-fail-space-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === spaceFailBuild.uuid));
        await stageIqTimer(server, admin, TEST_PORT, spaceFailBuild.uuid, { dingCount: 2 });

        ({ electronApp, window: iqWindow } = await launchClientFor(spaceFailBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '2 / 100', GUI_WAIT_OPTS);

        await iqWindow.keyboard.press('Space');
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', GUI_WAIT_OPTS);
        console.log('  ✓ a real SpaceBarFailed below the skip-offer threshold lands on the plain IQTestScreen');

        await electronApp.close().catch(() => {});
        electronApp = null;
        ({ electronApp, window: iqWindow } = await launchClientFor(spaceFailBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', GUI_WAIT_OPTS);
        console.log('  ✓ closing and reopening the client after the fail still lands on IQTestScreen, not IQTestActiveScreen (issue #88)');

        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, 'You may start the IQ test in', GUI_WAIT_OPTS);
        console.log('  ✓ pressing Begin again after reopening actually starts a fresh countdown instead of freezing');

        // --- issue #88 regression, missed-ding path: the same close/reopen check, but the
        // fail is triggered by a real elapsed DingWindowExpired timeout rather than a
        // space-bar press, since the two are indistinguishable at the wire level (both send
        // the same iqFailedEnvelope -- see Sync.elm's iqFailedEnvelope) and the issue asks
        // for both as separate scenarios.
        await electronApp.close().catch(() => {});
        electronApp = null;

        const missedDingBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-fail-missed-ding-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === missedDingBuild.uuid));
        await stageIqTimer(server, admin, TEST_PORT, missedDingBuild.uuid, {
            phase: 'IqDingShown',
            lastDing: 'RealDing',
            dingCount: 2,
        });

        ({ electronApp, window: iqWindow } = await launchClientFor(missedDingBuild.uuid));

        // Pressing Begin here resumes onto the already-shown ding (resumeCmd sends
        // iqResumeEnvelope, the server's resumeIqTimer resends the real ServerIqDing, and
        // the client schedules a genuine DingWindowExpired after IQTest.iqWindowDuration --
        // the same client-side timer a real missed ding uses).
        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '2 / 100', GUI_WAIT_OPTS);

        // Deliberately do not press Space -- let the real ~2s window elapse.
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', { timeoutMs: 8000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ a real missed ding (DingWindowExpired) below the skip-offer threshold lands on the plain IQTestScreen');

        await electronApp.close().catch(() => {});
        electronApp = null;
        ({ electronApp, window: iqWindow } = await launchClientFor(missedDingBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', GUI_WAIT_OPTS);
        console.log('  ✓ closing and reopening the client after a missed ding still lands on IQTestScreen, not IQTestActiveScreen (issue #88)');

        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, 'You may start the IQ test in', GUI_WAIT_OPTS);
        console.log('  ✓ pressing Begin again after reopening actually starts a fresh countdown instead of freezing');

        // --- issue #104: closing and reopening the client while caught by the fake-flash
        // trap used to leave the cutscene frozen forever on its first, blank sub-phase
        // (FfDelay) -- deriveIqScreen (Server.elm) always rebuilds a resumed IqIdleCaught
        // at FfDelay, but nothing locally scheduled the next FakeFlashNextPhase step to
        // actually advance off it (unlike the live catch, which does via SpaceBarPressed's
        // CaughtTrap case). Two variants, differing only in when the quit happens -- mid
        // cutscene vs. essentially the instant the trap is caught -- since deriveIqScreen's
        // "always restart from FfDelay" behavior is the same either way; both must resume
        // the animation and run it through to completion, not just one.
        await electronApp.close().catch(() => {});
        electronApp = null;

        const caughtMidBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-caught-mid-cutscene-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === caughtMidBuild.uuid));
        // dingCount below iqOfferMinDings (5) so no skip offer complicates the cutscene's
        // exit screen -- it must land on plain IQTestScreen. lastDing: 'TrapFake' stages a
        // real trap flash actively showing, so the catch below is a genuine SpaceBarPressed
        // through Game.IQTest.decideSpaceBar, not a simulated one.
        await stageIqTimer(server, admin, TEST_PORT, caughtMidBuild.uuid, {
            phase: 'IqDingShown',
            lastDing: 'TrapFake',
            dingCount: 2,
            totalDings: 4,
        });

        ({ electronApp, window: iqWindow } = await launchClientFor(caughtMidBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '2 / 4', GUI_WAIT_OPTS);

        await iqWindow.keyboard.press('Space');
        await waitForBodyTextIncluding(iqWindow, FAKE_FLASH_CAPTION_1, GUI_WAIT_OPTS);
        console.log('  ✓ a real SpaceBarPressed on the staged trap flash is a genuine catch (FakeFlashCaughtScreen)');

        // Let the live cutscene actually get partway through its animation (the first
        // caption fully visible) before quitting -- a genuine "mid-cutscene" close.
        await waitUntil(async () => (await fakeFlashCaptionVisible(iqWindow, FAKE_FLASH_CAPTION_1)) ? true : null, GUI_WAIT_OPTS);
        console.log('  ✓ the live cutscene is genuinely mid-animation (first caption visible) before quitting');

        await electronApp.close().catch(() => {});
        electronApp = null;
        ({ electronApp, window: iqWindow } = await launchClientFor(caughtMidBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitUntil(async () => (await fakeFlashCaptionVisible(iqWindow, FAKE_FLASH_CAPTION_1)) ? true : null, { timeoutMs: 5000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ closing and reopening mid-cutscene resumes the animation instead of freezing on FfDelay (#104)');

        // Fixed cutscene delays alone total ~9.5s before the count-up even starts -- give
        // real headroom for the full run to genuinely finish, not just resume.
        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', { timeoutMs: 18000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ the resumed cutscene runs all the way through and lands on the plain IQTestScreen, not stuck (#104)');

        await electronApp.close().catch(() => {});
        electronApp = null;

        const caughtImmediateBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-caught-immediate-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === caughtImmediateBuild.uuid));
        await stageIqTimer(server, admin, TEST_PORT, caughtImmediateBuild.uuid, {
            phase: 'IqDingShown',
            lastDing: 'TrapFake',
            dingCount: 2,
            totalDings: 4,
        });

        ({ electronApp, window: iqWindow } = await launchClientFor(caughtImmediateBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '2 / 4', GUI_WAIT_OPTS);

        // Quit the instant the catch itself registers (FakeFlashCaughtScreen is on the
        // DOM at all, still at its blank FfDelay sub-phase) rather than waiting for any
        // animation progress -- the earliest possible quit point, as opposed to the
        // mid-cutscene quit above.
        await iqWindow.keyboard.press('Space');
        await waitForBodyTextIncluding(iqWindow, FAKE_FLASH_CAPTION_1, GUI_WAIT_OPTS);
        console.log('  ✓ a real SpaceBarPressed on the staged trap flash is a genuine catch (FakeFlashCaughtScreen)');

        await electronApp.close().catch(() => {});
        electronApp = null;
        ({ electronApp, window: iqWindow } = await launchClientFor(caughtImmediateBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitUntil(async () => (await fakeFlashCaptionVisible(iqWindow, FAKE_FLASH_CAPTION_1)) ? true : null, { timeoutMs: 5000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ closing and reopening right as the trap is caught still resumes the animation, not frozen on FfDelay (#104)');

        await waitForBodyTextIncluding(iqWindow, 'IQ Test 2.0', { timeoutMs: 18000, intervalMs: GUI_WAIT_OPTS.intervalMs });
        console.log('  ✓ the resumed cutscene runs all the way through and lands on the plain IQTestScreen, not stuck (#104)');

        // --- issue #90: a song already finished must not replay after closing and
        // reopening the client. A freshly deployed build's very first stateRequest
        // resolves straight to the quiz's BlankScreen 0 (no IQ test gates it), so no
        // admin edit:state staging is needed to reach the quiz slide itself here.
        await electronApp.close().catch(() => {});
        electronApp = null;

        const songResumeBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-song-resume-question-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === songResumeBuild.uuid));

        let songWindow;
        ({ electronApp, window: songWindow } = await launchClientFor(songResumeBuild.uuid));

        await songWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await songWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(songWindow, 'Listen carefully...', GUI_WAIT_OPTS);
        console.log('  ✓ pressing Begin starts the first quiz slide (BlankScreen), listening to the song');

        // Let the placeholder song actually finish for real, exercising the genuine
        // TrackEnded -> quizSongEnded -> quizSongEndedAck round trip (see Main.elm's
        // TrackEnded/ServerQuizSongEndedAck handlers), not a staged shortcut -- this
        // proves the real reported flow reaches QuestionScreen normally.
        await songWindow.locator('#answer-input').waitFor({ state: 'visible', timeout: 12000 });
        console.log('  ✓ the song finishes for real and the client reveals QuestionScreen');

        await electronApp.close().catch(() => {});
        electronApp = null;
        ({ electronApp, window: songWindow } = await launchClientFor(songResumeBuild.uuid));

        await songWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await songWindow.getByRole('button', { name: 'Begin' }).click();
        await songWindow.locator('#answer-input').waitFor({ state: 'visible', timeout: 5000 });
        const replayedAudio = await readAudioState(songWindow, 'quiz-audio');
        assert.strictEqual(
            replayedAudio.exists, false,
            'expected #quiz-audio to be absent -- the song must not replay after reconnecting onto an already-heard slide (#90)'
        );
        console.log('  ✓ closing and reopening the client resumes directly onto QuestionScreen, without replaying the song (#90)');

        // --- issue #90 negative case: a song NOT yet finished must still replay in
        // full (not skip ahead) after closing and reopening, and the audio must be
        // genuinely playing, not just a rendered-but-inert element.
        await electronApp.close().catch(() => {});
        electronApp = null;

        const songReplayBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'quiz-song-replay-blank-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === songReplayBuild.uuid));

        let replayWindow;
        ({ electronApp, window: replayWindow } = await launchClientFor(songReplayBuild.uuid));

        await replayWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await replayWindow.getByRole('button', { name: 'Begin' }).click();
        await assertAudioPlaying(replayWindow, 'quiz-audio');
        console.log('  ✓ #quiz-audio is actually playing while listening to the first slide\'s song');

        // Close before the (3s) placeholder song ever finishes, so no quizSongEnded
        // report is ever sent for this uuid.
        await electronApp.close().catch(() => {});
        electronApp = null;
        ({ electronApp, window: replayWindow } = await launchClientFor(songReplayBuild.uuid));

        await replayWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await replayWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(replayWindow, 'Listen carefully...', GUI_WAIT_OPTS);
        await assertAudioPlaying(replayWindow, 'quiz-audio');
        console.log('  ✓ closing and reopening before the song ends still replays it in full, with real audio playing (#90)');

        // --- issue #52 regression: running the real admin edit:state tool (fetch, make no
        // changes, save) while a real, still-connected client is mid-ding must not resurrect
        // that ding on reconnect. Unlike every scenario above, edit:state itself is what
        // disconnects the live window here -- there's no explicit electronApp.close(), since
        // the whole point is that this is a same-window WS reconnect, not a process restart.
        await electronApp.close().catch(() => {});
        electronApp = null;

        const editStateDingBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-edit-state-ding-gui.dmg',
        });
        await waitUntil(() => registryHelper.readRegistry(server.tempDir).find((e) => e.uuid === editStateDingBuild.uuid));
        await stageIqTimer(server, admin, TEST_PORT, editStateDingBuild.uuid, {
            phase: 'IqDingShown',
            lastDing: 'RealDing',
            dingCount: 3,
            // dingDelay is milliseconds until the *next* ding once resumed onto
            // IqDingScheduled -- comfortably longer than the 4s window this test
            // watches below, so a legitimate next ding can't be mistaken for the
            // resurrected/resent one the fix prevents.
            dingDelay: 20000,
        });

        ({ electronApp, window: iqWindow } = await launchClientFor(editStateDingBuild.uuid));

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '3 / 100', GUI_WAIT_OPTS);
        console.log('  ✓ real client resumed onto the already-shown ding, mid-flash');

        // Admin runs edit:state on the same, still-connected uuid: fetch the current
        // document and save it straight back with no changes -- this kicks the window
        // (server-side closeClient), which auto-reconnects on its own.
        const resaved = await resaveIqTimerUnchanged(admin, TEST_PORT, editStateDingBuild.uuid);
        assert.strictEqual(resaved.iqTimer.phase, 'IqDingScheduled', 'edit:state snapshot must already be rewound, not the raw IqDingShown');

        await iqWindow.getByRole('button', { name: 'Begin' }).waitFor({ state: 'visible', timeout: 10000 });
        await iqWindow.getByRole('button', { name: 'Begin' }).click();
        await waitForBodyTextIncluding(iqWindow, '3 / 100', GUI_WAIT_OPTS);

        // Deliberately do not press Space, and give a real resent/re-timed-out ding (the
        // pre-fix behavior) the same ~2s window a genuine miss uses to reveal itself.
        await new Promise((resolve) => setTimeout(resolve, 4000));
        const bodyAfterWait = await bodyText(iqWindow);
        assert.ok(!bodyAfterWait.includes('IQ Test 2.0'), 'an unchanged edit:state save must not resurrect/resend the cleared ding');
        assert.ok(bodyAfterWait.includes('3 / 100'), 'the ding count must stay exactly what it was before the edit');
        console.log('  ✓ resuming after an unchanged edit:state save lands on the idle IQ screen, not the ding screen, with the count unchanged (issue #52)');

        console.log('\nGUI suite passed.');
    } finally {
        if (electronApp) await electronApp.close().catch(() => {});
        if (server) await server.stop().catch(() => {});
        if (hadExistingUuidFile) fs.writeFileSync(APP_UUID_PATH, backedUpUuid);
        else fs.rmSync(APP_UUID_PATH, { force: true });
        if (!hadExistingAudioAsset) fs.rmSync(AUDIO_ASSET_PATH, { force: true });
        if (!hadExistingVideoAsset) fs.rmSync(LOUD_VIDEO_ASSET_PATH, { force: true });
        if (!hadExistingQuizSongAsset) fs.rmSync(QUIZ_SONG_ASSET_PATH, { force: true });
        await globalTeardown();
    }
}

main().catch((err) => {
    console.error('\nGUI suite FAILED:', err);
    process.exitCode = 1;
});
