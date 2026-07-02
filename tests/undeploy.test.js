'use strict';

const fs = require('fs');
const path = require('path');
const { startTestServer } = require('./helpers/testServer');
const { AdminClient } = require('./helpers/adminAuth');
const distClient = require('./helpers/distClient');
const { waitUntil } = require('./helpers/waitUntil');

const TEST_PORT = 19448;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;
let admin;
let build;

function readRegistry() {
    const file = path.join(server.tempDir, 'app-builds', 'builds.jsonl');
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

function buildFilePath(filename) {
    return path.join(server.tempDir, 'app-builds', filename);
}

// One deployed build is shared across this file's tests: non-destructive checks run
// first, the destructive undeploy runs last.
describe('undeploy', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
        admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'Ryan Birthday-2.0.0-universal.dmg',
        });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('lists the current uuid/filename/platform without removing anything', async () => {
        const { authResult, entries } = await distClient.listBuilds(TEST_PORT, admin);
        expect(authResult.success).toBe(true);

        const entry = entries.find((e) => e.uuid === build.uuid);
        expect(entry).toBeTruthy();
        expect(entry.filename).toBe(build.filename);
        expect(entry.platform).toBe('mac');

        // still on disk / in the registry — nothing was removed by listing. (Polling here
        // too, consistent with the rest of this suite: the deploy in beforeAll acks before
        // its registry write is guaranteed to have landed on disk.)
        expect(fs.existsSync(buildFilePath(build.filename))).toBe(true);
        await waitUntil(() => readRegistry().some((e) => e.uuid === build.uuid));
    });

    test('removes the file and the registry entry when a uuid is provided (no kick — that is Tier 2)', async () => {
        const { authResult, ack } = await distClient.undeploy(TEST_PORT, admin, build.uuid);
        expect(authResult.success).toBe(true);
        expect(ack).toBeTruthy();

        // distUndeploy is handled in src/Server.elm (so it can kick a live player via
        // connectedPlayers), which dispatches the registry write, the file unlink, and the
        // admin ack as separate ports in one Cmd.batch — same as deploy/edit-state, this
        // doesn't guarantee the write lands before the ack arrives, so poll for both.
        await waitUntil(() => !readRegistry().some((e) => e.uuid === build.uuid));
        await waitUntil(() => !fs.existsSync(buildFilePath(build.filename)));
    });
});
