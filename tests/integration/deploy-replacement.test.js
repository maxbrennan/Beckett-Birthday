'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { connect } = require('../helpers/protocolClient');
const { waitUntil } = require('../helpers/waitUntil');
const { resolveReplacement } = require('../../scripts/deploy-replacement.js');

const TEST_PORT = 19451;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;

function readRegistry() {
    const file = path.join(server.tempDir, 'app-builds', 'builds.jsonl');
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

describe('deploy-replacement', () => {
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

    test('replacing a build carries over state, kicks the old player, and retires the old uuid', async () => {
        const oldBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-replace-old.dmg',
        });

        const { conn: playerConn, result: initialResult } = await connectAsPlayer(TEST_PORT, oldBuild.uuid);
        expect(initialResult.payload).toBe('stateUpdate');
        expect(JSON.parse(initialResult.stateUpdate.json)).toEqual({});

        const preservedState = { screen: 'IQTest', score: 7 };
        playerConn.send({ stateUpdate: { json: JSON.stringify(preservedState) } });
        await playerConn.waitFor((m) => m.payload === 'stateUpdateAck');

        const replacement = await distClient.replaceBuild(TEST_PORT, admin, oldBuild.uuid, {
            platform: 'mac',
            filename: 'Ryan Birthday-replace-new.dmg',
        });

        // the live old-uuid player is disconnected once the replacement completes.
        await playerConn.closed();

        const entries = await waitUntil(() => {
            const all = readRegistry();
            const newEntry = all.find((e) => e.uuid === replacement.uuid);
            const oldEntry = all.find((e) => e.uuid === oldBuild.uuid);
            return newEntry && !oldEntry ? { newEntry, oldEntry } : null;
        });
        expect(entries.oldEntry).toBeUndefined();
        expect(entries.newEntry.filename).toBe(replacement.filename);
        expect(entries.newEntry.state).toEqual(preservedState);

        // a replacement starts locked pending an admin state edit: neither WS connects
        // nor downloads are allowed for the new uuid until that edit is saved.
        expect(entries.newEntry.pendingStateEdit).toBe(true);

        const { result: pendingResult } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        expect(pendingResult.payload).toBe('stateRequestRejected');
        expect(pendingResult.stateRequestRejected.reason).toBe('state is being edited by admin');

        const lockedDownload = await distClient.download(TEST_PORT, replacement.uuid);
        expect(lockedDownload.statusCode).toBe(423);

        // admin resolves the pending edit — the edit payload shows the carried-over state.
        const { authResult: editAuth, conn: editConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, replacement.uuid);
        expect(editAuth.success).toBe(true);
        expect(JSON.parse(json)).toEqual(preservedState);
        const saveResult = await distClient.saveStateEdit(editConn, replacement.uuid, JSON.stringify(preservedState));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await editConn.close();

        const unlockedEntry = await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === replacement.uuid);
            return found && found.pendingStateEdit === false ? found : null;
        });
        expect(unlockedEntry.state).toEqual(preservedState);

        const { result: newResult } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        expect(newResult.payload).toBe('stateUpdate');
        expect(JSON.parse(newResult.stateUpdate.json)).toEqual(preservedState);

        const okDownload = await distClient.download(TEST_PORT, replacement.uuid);
        expect(okDownload.statusCode).toBe(200);

        const { result: oldResult } = await connectAsPlayer(TEST_PORT, oldBuild.uuid);
        expect(oldResult.payload).toBe('stateRequestRejected');
        expect(oldResult.stateRequestRejected.reason).toBe('unknown uuid');
    });

    test('replacing a never-deployed oldUuid still succeeds, with no state to carry over, and is still gated pending a state edit', async () => {
        const oldUuid = crypto.randomUUID();

        const replacement = await distClient.replaceBuild(TEST_PORT, admin, oldUuid, {
            platform: 'mac',
            filename: 'Ryan Birthday-replace-neverdeployed.dmg',
        });

        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === replacement.uuid));
        expect(entry.state).toBeNull();
        expect(entry.pendingStateEdit).toBe(true);

        // gating applies uniformly, even though there was no old state to carry over.
        const { result: pendingResult } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        expect(pendingResult.payload).toBe('stateRequestRejected');
        expect(pendingResult.stateRequestRejected.reason).toBe('state is being edited by admin');

        const lockedDownload = await distClient.download(TEST_PORT, replacement.uuid);
        expect(lockedDownload.statusCode).toBe(423);

        const { authResult: editAuth, conn: editConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, replacement.uuid);
        expect(editAuth.success).toBe(true);
        expect(JSON.parse(json)).toEqual({});
        const newState = { screen: 'BeginScreen' };
        const saveResult = await distClient.saveStateEdit(editConn, replacement.uuid, JSON.stringify(newState));
        expect(saveResult.payload).toBe('distStateEditSaveAck');
        await editConn.close();

        await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === replacement.uuid);
            return found && found.pendingStateEdit === false ? found : null;
        });

        const { result } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        expect(result.payload).toBe('stateUpdate');
        expect(JSON.parse(result.stateUpdate.json)).toEqual(newState);

        const okDownload = await distClient.download(TEST_PORT, replacement.uuid);
        expect(okDownload.statusCode).toBe(200);
    });

    test('a distReplaceComplete with a newUuid that was never registered gets no ack', async () => {
        const registeredUuid = crypto.randomUUID();

        const conn = await connect(TEST_PORT);
        conn.send({ distRegister: { uuid: registeredUuid, platform: 'mac' } });
        const authResult = await admin.respondToChallenge(conn);
        expect(authResult.success).toBe(true);
        await conn.waitFor((m) => m.payload === 'distRegisterAck');

        conn.send({
            distReplaceComplete: {
                newUuid: crypto.randomUUID(),
                oldUuid: crypto.randomUUID(),
                filename: 'Ryan Birthday-replace-mismatch.dmg',
            },
        });

        await expect(conn.waitFor((m) => m.payload === 'distReplaceCompleteAck', 1000)).rejects.toThrow(/timed out/);
        await conn.close();
    });

    test('replacing with a filename that collides with an unrelated build retires that build too', async () => {
        const collidingFilename = 'Ryan Birthday-replace-collision.dmg';
        const unrelated = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: collidingFilename,
        });
        const oldBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-replace-collision-old.dmg',
        });

        // this filename-as-unique-key behavior isn't specific to replacement — plain
        // deploy's ClientDistComplete already drops any existing row with the same
        // filename, live or not; replacement just ANDs that with the old-uuid drop.
        const replacement = await distClient.replaceBuild(TEST_PORT, admin, oldBuild.uuid, {
            platform: 'mac',
            filename: collidingFilename,
        });

        const entries = await waitUntil(() => {
            const all = readRegistry();
            const newEntry = all.find((e) => e.uuid === replacement.uuid);
            const stillPresent = all.some((e) => e.uuid === unrelated.uuid || e.uuid === oldBuild.uuid);
            return newEntry && !stillPresent ? all : null;
        });
        expect(entries.find((e) => e.uuid === unrelated.uuid)).toBeUndefined();
        expect(entries.find((e) => e.uuid === oldBuild.uuid)).toBeUndefined();
        expect(entries.find((e) => e.uuid === replacement.uuid).filename).toBe(collidingFilename);
    });

    // Items below prove that admin-auth validity — not the oldUuid parameter given to a
    // replacement attempt — is what gates distList/registry enumeration. Auth failure
    // closes the connection in AuthCompleted (src/Server.elm) before distReplaceComplete
    // (and thus oldUuid) is ever consumed, so the "no uuid" and "invalid uuid" cases below
    // are necessarily near-identical to each other and to deploy-unauth.test.js's pattern;
    // they exist to document that explicitly, not because they exercise different code.

    test('replacement attempt with an empty oldUuid and invalid auth never creates an entry and is invisible to distList', async () => {
        const wrongAdmin = new AdminClient({ username: USERNAME, password: 'wrong-password' });
        const wouldBeNewUuid = crypto.randomUUID();

        const conn = await connect(TEST_PORT);
        conn.send({ distRegister: { uuid: wouldBeNewUuid, platform: 'mac' } });
        const authResult = await wrongAdmin.respondToChallenge(conn, { preferKey: false });
        expect(authResult.success).toBe(false);

        // auth fails before distReplaceComplete (oldUuid = '') would ever be sent — no
        // ack, no upload token, nothing to replace.
        await expect(conn.waitFor((m) => m.payload === 'distRegisterAck', 500)).rejects.toThrow();
        await conn.closed();

        // prove nothing was created, via a genuinely-authenticated distList call.
        const { authResult: listAuth, entries } = await distClient.listBuilds(TEST_PORT, admin);
        expect(listAuth.success).toBe(true);
        expect(entries.some((e) => e.uuid === wouldBeNewUuid)).toBe(false);
    });

    test('replacement attempt with a nonexistent oldUuid and invalid auth never creates an entry and is invisible to distList', async () => {
        const wrongAdmin = new AdminClient({ username: USERNAME, password: 'wrong-password' });
        const wouldBeNewUuid = crypto.randomUUID();

        const conn = await connect(TEST_PORT);
        conn.send({ distRegister: { uuid: wouldBeNewUuid, platform: 'mac' } });
        const authResult = await wrongAdmin.respondToChallenge(conn, { preferKey: false });
        expect(authResult.success).toBe(false);

        // same shape as above — a syntactically valid but never-registered oldUuid is
        // conceptually what would have been sent, but auth fails first so it never is.
        await expect(conn.waitFor((m) => m.payload === 'distRegisterAck', 500)).rejects.toThrow();
        await conn.closed();

        const { authResult: listAuth, entries } = await distClient.listBuilds(TEST_PORT, admin);
        expect(listAuth.success).toBe(true);
        expect(entries.some((e) => e.uuid === wouldBeNewUuid)).toBe(false);
    });

    test('replacing with an empty oldUuid and valid auth succeeds and is visible via distList', async () => {
        const replacement = await distClient.replaceBuild(TEST_PORT, admin, '', {
            platform: 'mac',
            filename: 'Ryan Birthday-replace-empty-olduuid.dmg',
        });

        // distList projects only {uuid, filename, platform} (server/index.js) regardless
        // of pendingStateEdit, so no state-edit resolution is needed to observe this.
        const { authResult, entries } = await waitUntil(async () => {
            const res = await distClient.listBuilds(TEST_PORT, admin);
            return res.entries.some((e) => e.uuid === replacement.uuid) ? res : null;
        });
        expect(authResult.success).toBe(true);
        expect(entries.some((e) => e.uuid === replacement.uuid)).toBe(true);
        // no crash, no phantom "" entry — confirms List.filter (uuid /= oldUuid) with
        // oldUuid = "" is a no-op filter, not an accidental match on some other row.
        expect(entries.some((e) => e.uuid === '')).toBe(false);
    });

    test('replacing with a never-registered oldUuid and valid auth succeeds and is visible via distList', async () => {
        const oldUuid = crypto.randomUUID();
        const replacement = await distClient.replaceBuild(TEST_PORT, admin, oldUuid, {
            platform: 'mac',
            filename: 'Ryan Birthday-replace-neverregistered-list.dmg',
        });

        const { authResult, entries } = await waitUntil(async () => {
            const res = await distClient.listBuilds(TEST_PORT, admin);
            return res.entries.some((e) => e.uuid === replacement.uuid) ? res : null;
        });
        expect(authResult.success).toBe(true);
        expect(entries.some((e) => e.uuid === replacement.uuid)).toBe(true);
    });

    // The CLI (scripts/deploy-replacement.js) gates on the distList result BEFORE
    // generating a uuid or running electron-builder — the server protocol accepts any
    // oldUuid regardless of existence (proven by the tests above), so refusing a
    // nonexistent uuid is client-side logic. resolveReplacement is that decision; its
    // pure logic (no server needed) is unit-tested in tests/unit/deploy-replacement.test.js.
    describe('resolveReplacement (CLI pre-build gate)', () => {
        test('validates against the real distList projection a deployed build produces', async () => {
            const deployed = await distClient.deployBuild(TEST_PORT, admin, {
                platform: 'mac',
                filename: 'Ryan Birthday-replace-cli-gate.dmg',
            });

            const { authResult, entries: live } = await waitUntil(async () => {
                const res = await distClient.listBuilds(TEST_PORT, admin);
                return res.entries.some((e) => e.uuid === deployed.uuid) ? res : null;
            });
            expect(authResult.success).toBe(true);

            // a real deployed uuid is deployable; a random one is refused before building.
            expect(resolveReplacement(live, deployed.uuid).action).toBe('proceed');
            expect(resolveReplacement(live, crypto.randomUUID()).action).toBe('abort');
        });
    });

    // Nested (not a sibling describe) so it reuses this file's shared server/admin
    // fixtures from the beforeAll above, rather than spinning up a second server
    // subprocess just to re-run edit-state mechanics.
    describe('edit-state mechanics reused across a uuid switch', () => {
        test('edit-state request/save/invalid-json all work identically against a uuid that came from a replacement, not a fresh deploy', async () => {
            // start with a uuid from a fresh deploy...
            const oldBuild = await distClient.deployBuild(TEST_PORT, admin, {
                platform: 'mac',
                filename: 'Ryan Birthday-switch-old.dmg',
            });

            const { authResult: listAuth1, entries: entries1 } = await distClient.listBuilds(TEST_PORT, admin);
            expect(listAuth1.success).toBe(true);
            expect(entries1.some((e) => e.uuid === oldBuild.uuid)).toBe(true);

            // ...then switch to the replacement's newUuid partway through.
            const replacement = await distClient.replaceBuild(TEST_PORT, admin, oldBuild.uuid, {
                platform: 'mac',
                filename: 'Ryan Birthday-switch-new.dmg',
            });

            // newUuid is already pending (mandatory post-replacement gating) — resolving
            // it via requestStateEdit/saveStateEdit mirrors edit-state.test.js's
            // "successfully edits the state when a uuid is provided", just entered via
            // replacement instead of an admin's on-demand distStateEdit.
            const { authResult: editAuth, conn, json } = await distClient.requestStateEdit(TEST_PORT, admin, replacement.uuid);
            expect(editAuth.success).toBe(true);
            expect(JSON.parse(json)).toEqual({});

            const newState = { screen: 'BeginScreen', jeopardyPlaying: false };
            const saveResult = await distClient.saveStateEdit(conn, replacement.uuid, JSON.stringify(newState));
            expect(saveResult.payload).toBe('distStateEditSaveAck');
            await conn.close();

            const entry = await waitUntil(() => {
                const found = readRegistry().find((e) => e.uuid === replacement.uuid);
                return found && found.pendingStateEdit === false ? found : null;
            });
            expect(entry.state).toEqual(newState);

            // now exercise the invalid-JSON fallback against the SAME (already-unlocked)
            // newUuid, re-entering pending state via the manual distStateEdit trigger
            // this time — proving the mandatory (post-replacement) and optional
            // (on-demand) triggers into pendingStateEdits share identical save/invalid-
            // json code paths.
            const { conn: conn2, json: json2 } = await distClient.requestStateEdit(TEST_PORT, admin, replacement.uuid);
            expect(JSON.parse(json2)).toEqual(newState);

            const badResult = await distClient.saveStateEdit(conn2, replacement.uuid, 'this is not valid json');
            expect(badResult.payload).toBe('stateRequestRejected');
            expect(badResult.stateRequestRejected.reason).toBe('invalid json');
            await conn2.close();
            // NOTE: replacement.uuid is now stuck in pendingStateEdits again (pre-
            // existing quirk, see tests/edit-state.test.js) — this is the last
            // assertion needing it.
        });
    });
});
