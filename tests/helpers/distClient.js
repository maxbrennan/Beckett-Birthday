'use strict';

const crypto = require('crypto');
const https = require('https');
const { connect } = require('./protocolClient');

function httpUpload(port, { token, filename, contents }) {
    return new Promise((resolve, reject) => {
        const req = https.request(
            {
                hostname: 'localhost',
                port,
                path: '/upload',
                method: 'POST',
                rejectUnauthorized: false, // self-signed test cert
                headers: {
                    Authorization: `Bearer ${token}`,
                    'X-Filename': filename,
                    'Content-Type': 'application/octet-stream',
                    'Content-Length': contents.length,
                },
            },
            (res) => {
                let body = '';
                res.on('data', (chunk) => { body += chunk; });
                res.on('end', () => {
                    if (res.statusCode !== 200) {
                        reject(new Error(`upload failed: ${res.statusCode} ${body}`));
                    } else {
                        resolve();
                    }
                });
            }
        );
        req.on('error', reject);
        req.end(contents);
    });
}

// GET /<uuid> — mirrors how a player's browser/download link hits the server.
function download(port, uuid) {
    return new Promise((resolve, reject) => {
        const req = https.request(
            { hostname: 'localhost', port, path: `/${uuid}`, method: 'GET', rejectUnauthorized: false },
            (res) => {
                const chunks = [];
                res.on('data', (chunk) => chunks.push(chunk));
                res.on('end', () => resolve({ statusCode: res.statusCode, body: Buffer.concat(chunks) }));
            }
        );
        req.on('error', reject);
        req.end();
    });
}

// Full distRegister -> admin auth -> HTTPS upload -> distComplete cycle. Uploads a small
// dummy buffer instead of a real electron-builder artifact — the server's registry/auth/
// download behavior doesn't depend on what bytes were uploaded, and building a real signed
// DMG/EXE per test run isn't needed to exercise that behavior.
async function deployBuild(port, admin, { platform = 'mac', filename, contents } = {}) {
    const uuid = crypto.randomUUID();
    const finalFilename = filename || `test-build-${uuid}.bin`;
    const finalContents = contents !== undefined ? contents : Buffer.from(`dummy build ${uuid}`);

    const conn = await connect(port);
    conn.send({ distRegister: { uuid, platform } });
    const authResult = await admin.respondToChallenge(conn);
    if (!authResult.success) {
        await conn.closed();
        throw new Error(`admin auth failed while deploying (level=${authResult.level})`);
    }

    const ackMsg = await conn.waitFor((m) => m.payload === 'ack');
    const uploadToken = ackMsg.ack.uploadToken;

    await httpUpload(port, { token: uploadToken, filename: finalFilename, contents: finalContents });

    conn.send({ distComplete: { uuid, filename: finalFilename } });
    await conn.waitFor((m) => m.payload === 'ack');
    await conn.close();

    return { uuid, filename: finalFilename, platform, contents: finalContents };
}

async function undeploy(port, admin, uuid) {
    const conn = await connect(port);
    conn.send({ distUndeploy: { uuid } });
    const authResult = await admin.respondToChallenge(conn);
    if (!authResult.success) {
        await conn.closed();
        return { authResult, ack: null };
    }
    const ackMsg = await conn.waitFor((m) => m.payload === 'ack');
    return { authResult, ack: ackMsg.ack };
}

async function listBuilds(port, admin) {
    const conn = await connect(port);
    conn.send({ distList: {} });
    const authResult = await admin.respondToChallenge(conn);
    if (!authResult.success) {
        await conn.closed();
        return { authResult, entries: null };
    }
    const resultMsg = await conn.waitFor((m) => m.payload === 'distListResult');
    return { authResult, entries: resultMsg.distListResult.entries };
}

// Step 1 of edit-state: requests the current state and keeps `conn` open, since the
// server gates distStateEditSave on the same clientId having just passed this auth.
async function requestStateEdit(port, admin, uuid) {
    const conn = await connect(port);
    conn.send({ distStateEdit: { uuid } });
    const authResult = await admin.respondToChallenge(conn);
    if (!authResult.success) {
        await conn.closed();
        return { authResult, conn: null, json: null };
    }
    const payloadMsg = await conn.waitFor((m) => m.payload === 'distStateEditPayload');
    return { authResult, conn, json: payloadMsg.distStateEditPayload.json };
}

// Step 2 of edit-state: submits edited JSON on the same `conn` returned by
// requestStateEdit. Resolves to either an `ack` (saved) or `stateRequestRejected`
// (invalid JSON — server leaves the previous state untouched).
async function saveStateEdit(conn, uuid, json) {
    conn.send({ distStateEditSave: { uuid, json } });
    return conn.waitFor((m) => m.payload === 'ack' || m.payload === 'stateRequestRejected');
}

module.exports = { deployBuild, undeploy, listBuilds, requestStateEdit, saveStateEdit, download, httpUpload };
