'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { connectAsPlayer } = require('./helpers/playerClient');
const { connect } = require('./helpers/protocolClient');
const { waitUntil } = require('./helpers/waitUntil');

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
        await playerConn.waitFor((m) => m.payload === 'ack');

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

        const { result: newResult } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        expect(newResult.payload).toBe('stateUpdate');
        expect(JSON.parse(newResult.stateUpdate.json)).toEqual(preservedState);

        const { result: oldResult } = await connectAsPlayer(TEST_PORT, oldBuild.uuid);
        expect(oldResult.payload).toBe('stateRequestRejected');
        expect(oldResult.stateRequestRejected.reason).toBe('unknown uuid');
    });

    test('replacing a never-deployed oldUuid still succeeds, with no state to carry over', async () => {
        const oldUuid = crypto.randomUUID();

        const replacement = await distClient.replaceBuild(TEST_PORT, admin, oldUuid, {
            platform: 'mac',
            filename: 'Ryan Birthday-replace-neverdeployed.dmg',
        });

        const { result } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        expect(result.payload).toBe('stateUpdate');
        expect(JSON.parse(result.stateUpdate.json)).toEqual({});

        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === replacement.uuid));
        expect(entry.state).toBeNull();
    });

    test('a distReplaceComplete with a newUuid that was never registered gets no ack', async () => {
        const registeredUuid = crypto.randomUUID();

        const conn = await connect(TEST_PORT);
        conn.send({ distRegister: { uuid: registeredUuid, platform: 'mac' } });
        const authResult = await admin.respondToChallenge(conn);
        expect(authResult.success).toBe(true);
        await conn.waitFor((m) => m.payload === 'ack');

        conn.send({
            distReplaceComplete: {
                newUuid: crypto.randomUUID(),
                oldUuid: crypto.randomUUID(),
                filename: 'Ryan Birthday-replace-mismatch.dmg',
            },
        });

        await expect(conn.waitFor((m) => m.payload === 'ack', 1000)).rejects.toThrow(/timed out/);
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
});
