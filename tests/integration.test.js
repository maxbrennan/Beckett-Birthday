'use strict';

const WebSocket = require('ws');
const { startTestServer } = require('./helpers/testServer');

const TEST_PORT = 19443;

let server;

describe('integration', () => {
    beforeAll(async () => {
        server = await startTestServer({ port: TEST_PORT });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('server accepts WebSocket connections', async () => {
        // rejectUnauthorized: false required for the self-signed certs
        const ws = new WebSocket(`wss://localhost:${TEST_PORT}`, { rejectUnauthorized: false });
        await new Promise((resolve, reject) => {
            ws.on('open', resolve);
            ws.on('error', reject);
        });
        ws.close();
        await new Promise((resolve) => ws.on('close', resolve));
    }, 10000);
});
