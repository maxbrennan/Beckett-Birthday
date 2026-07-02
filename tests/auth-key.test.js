'use strict';

const { startTestServer } = require('./helpers/testServer');
const { connect } = require('./helpers/protocolClient');
const { AdminClient } = require('./helpers/adminAuth');

const TEST_PORT = 19445;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;

// `distList` is used as the neutral trigger, same as tests/auth-password.test.js.
async function authOnce(admin, opts) {
    const conn = await connect(TEST_PORT);
    conn.send({ distList: {} });
    const result = await admin.respondToChallenge(conn, opts);
    return { conn, result };
}

// Each test builds its own AdminClient and does its own initial password auth, so these
// five scenarios (mirroring five sibling/child checklist items) don't depend on each
// other's ordering or leftover state.
describe('key auth', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('succeeds on a second connection using the stored key', async () => {
        const admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        const { conn: firstConn, result: first } = await authOnce(admin, { preferKey: false });
        expect(first.success).toBe(true);
        await firstConn.close();

        const { conn, result } = await authOnce(admin); // preferKey defaults true, key now exists
        expect(result.method).toBe('key');
        expect(result.success).toBe(true);
        expect(result.level).toBe(2);
        await conn.close();
    });

    test('falls back to password auth when the stored key is wrong, and succeeds with the correct password', async () => {
        const admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        const { conn: firstConn, result: first } = await authOnce(admin, { preferKey: false });
        expect(first.success).toBe(true);
        await firstConn.close();

        admin.corruptKey();

        // server closes the socket on auth failure, so a fresh connection is required to retry
        const { conn: keyConn, result: keyResult } = await authOnce(admin);
        expect(keyResult.method).toBe('key');
        expect(keyResult.success).toBe(false);
        await keyConn.closed();

        const { conn, result } = await authOnce(admin, { preferKey: false });
        expect(result.method).toBe('password');
        expect(result.success).toBe(true);
        await conn.close();
    });

    test('fails when a wrong password is given after falling back from a wrong stored key', async () => {
        const admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        const { conn: firstConn, result: first } = await authOnce(admin, { preferKey: false });
        expect(first.success).toBe(true);
        await firstConn.close();

        admin.corruptKey();
        const { conn: keyConn, result: keyResult } = await authOnce(admin);
        expect(keyResult.success).toBe(false);
        await keyConn.closed();

        admin.password = 'not-the-right-password';
        const { conn, result } = await authOnce(admin, { preferKey: false });
        expect(result.method).toBe('password');
        expect(result.success).toBe(false);
        await conn.closed();
    });

    test('falls back to password auth when the stored key is missing, and succeeds with the correct password', async () => {
        const admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        const { conn: firstConn, result: first } = await authOnce(admin, { preferKey: false });
        expect(first.success).toBe(true);
        await firstConn.close();

        admin.deleteKey();

        // preferKey defaults true, but hasUsableKey() is false with no key files on disk,
        // so this already takes the password path — same as the real client's fallback.
        const { conn, result } = await authOnce(admin);
        expect(result.method).toBe('password');
        expect(result.success).toBe(true);
        await conn.close();
    });

    test('fails when a wrong password is given after falling back from a missing stored key', async () => {
        const admin = new AdminClient({ username: USERNAME, password: PASSWORD });
        const { conn: firstConn, result: first } = await authOnce(admin, { preferKey: false });
        expect(first.success).toBe(true);
        await firstConn.close();

        admin.deleteKey();
        admin.password = 'not-the-right-password';
        const { conn, result } = await authOnce(admin);
        expect(result.method).toBe('password');
        expect(result.success).toBe(false);
        await conn.closed();
    });
});
