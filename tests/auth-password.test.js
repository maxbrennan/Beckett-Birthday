'use strict';

const fs = require('fs');
const path = require('path');
const { startTestServer } = require('./helpers/testServer');
const { connect } = require('./helpers/protocolClient');
const { AdminClient } = require('./helpers/adminAuth');

const TEST_PORT = 19444;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;

// `distList` is used as the neutral trigger for these auth-focused tests: it's the one
// admin-gated operation that only reads state (no file/registry mutation), so it doesn't
// entangle these assertions with deploy/undeploy/edit-state side effects.
describe('password auth', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('fails when the wrong password is provided', async () => {
        const admin = new AdminClient({ username: USERNAME, password: 'not-the-right-password' });
        const conn = await connect(TEST_PORT);
        conn.send({ distList: {} });

        const result = await admin.respondToChallenge(conn, { preferKey: false });

        expect(result.method).toBe('password');
        expect(result.success).toBe(false);
        await conn.closed();
    });

    test('succeeds with correct credentials, registers the uuid, and persists a private key', async () => {
        const admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        const conn = await connect(TEST_PORT);
        conn.send({ distList: {} });

        const result = await admin.respondToChallenge(conn, { preferKey: false });

        expect(result.method).toBe('password');
        expect(result.success).toBe(true);
        expect(result.level).toBe(2);
        expect(result.uuid).toBeTruthy();

        // "a private key should be saved" — our reference client's own key material
        expect(fs.existsSync(admin.privateKeyPath)).toBe(true);
        expect(fs.existsSync(admin.publicKeyPath)).toBe(true);

        // server registered the uuid, bound to the public key we sent
        const uuidsFile = path.join(server.tempDir, '.auth', 'uuids.jsonl');
        const rows = fs
            .readFileSync(uuidsFile, 'utf8')
            .trim()
            .split('\n')
            .map((line) => JSON.parse(line));
        const row = rows.find((r) => r.uuid === result.uuid);

        expect(row).toBeTruthy();
        expect(row.level).toBe(2);
        expect(row.public_key_pem.trim()).toBe(fs.readFileSync(admin.publicKeyPath, 'utf8').trim());

        await conn.close();
    });
});
