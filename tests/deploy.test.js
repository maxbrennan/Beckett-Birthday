'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { waitUntil } = require('./helpers/waitUntil');

const TEST_PORT = 19447;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;
let initialBuild;

function readRegistry() {
    const file = path.join(server.tempDir, 'app-builds', 'builds.jsonl');
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

describe('deploy', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
        admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        initialBuild = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-1.0.0-universal.dmg',
        });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('initial deploy is recorded in the registry', async () => {
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === initialBuild.uuid));
        expect(entry.filename).toBe(initialBuild.filename);
        expect(entry.platform).toBe('mac');
    });

    test('deploying another build on a new version results in 2 registry entries for those filenames', async () => {
        const newVersion = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-1.0.1-universal.dmg',
        });

        const entries = await waitUntil(() => {
            const all = readRegistry();
            const matching = all.filter((e) => e.uuid === initialBuild.uuid || e.uuid === newVersion.uuid);
            return matching.length === 2 ? all : null;
        });
        expect(entries.find((e) => e.filename === initialBuild.filename)).toBeTruthy();
        expect(entries.find((e) => e.filename === newVersion.filename)).toBeTruthy();
    });

    test('deploying a build on the same version results in exactly 1 registry entry for that filename, with a new uuid', async () => {
        const sameFilename = 'Ryan Birthday-9.9.9-universal.dmg';
        const first = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: sameFilename });
        const second = await distClient.deployBuild(TEST_PORT, admin, { platform: 'mac', filename: sameFilename });

        expect(second.uuid).not.toBe(first.uuid);

        const entries = await waitUntil(() => {
            const matching = readRegistry().filter((e) => e.filename === sameFilename);
            return matching.length === 1 && matching[0].uuid === second.uuid ? matching : null;
        });
        expect(entries).toHaveLength(1);
        expect(entries[0].uuid).toBe(second.uuid);
    });

    test('downloading a deployed build via /<uuid> works', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, { platform: 'win', filename: 'download-me.exe' });
        await waitUntil(() => readRegistry().some((e) => e.uuid === build.uuid));
        const res = await distClient.download(TEST_PORT, build.uuid);
        expect(res.statusCode).toBe(200);
        expect(res.body.equals(build.contents)).toBe(true);
    });

    test('downloading a non-deployed/wrong uuid does not work', async () => {
        const wrongUuid = crypto.randomUUID();
        const res = await distClient.download(TEST_PORT, wrongUuid);
        expect(res.statusCode).toBe(404);
    });
});
