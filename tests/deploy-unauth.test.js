'use strict';

const crypto = require('crypto');
const { startTestServer } = require('./helpers/testServer');
const { connect } = require('./helpers/protocolClient');
const { AdminClient } = require('./helpers/adminAuth');

const TEST_PORT = 19446;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';

let server;

describe('unauthenticated admin operations', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('distRegister (deploy) fails without valid credentials', async () => {
        const admin = new AdminClient({ username: USERNAME, password: 'wrong-password' });
        const conn = await connect(TEST_PORT);
        conn.send({ distRegister: { uuid: crypto.randomUUID(), platform: 'mac' } });

        const result = await admin.respondToChallenge(conn, { preferKey: false });
        expect(result.success).toBe(false);

        // no ack/upload token should ever arrive for a failed auth
        await expect(conn.waitFor((m) => m.payload === 'ack', 500)).rejects.toThrow();
        await conn.closed();
    });

    test('distUndeploy fails without valid credentials, with a uuid provided', async () => {
        const admin = new AdminClient({ username: USERNAME, password: 'wrong-password' });
        const conn = await connect(TEST_PORT);
        conn.send({ distUndeploy: { uuid: crypto.randomUUID() } });

        const result = await admin.respondToChallenge(conn, { preferKey: false });
        expect(result.success).toBe(false);

        await expect(conn.waitFor((m) => m.payload === 'ack', 500)).rejects.toThrow();
        await conn.closed();
    });

    test('distList fails without valid credentials, with no uuid provided, and does not leak the registry', async () => {
        const admin = new AdminClient({ username: USERNAME, password: 'wrong-password' });
        const conn = await connect(TEST_PORT);
        conn.send({ distList: {} });

        const result = await admin.respondToChallenge(conn, { preferKey: false });
        expect(result.success).toBe(false);

        await expect(conn.waitFor((m) => m.payload === 'distListResult', 500)).rejects.toThrow();
        await conn.closed();
    });
});
