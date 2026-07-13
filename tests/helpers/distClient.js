'use strict';

const crypto = require('crypto');
const https = require('https');
const { connect } = require('./protocolClient');
const { uploadBuild: httpUpload } = require('../../scripts/deploy.js');
const { TEST_QUIZ_QUESTIONS } = require('./testServer.js');

// GET /<uuid> — mirrors how a player's browser/download link hits the server. There's no
// existing production "download client" to reuse here — real downloads are just a
// browser GETing the URL directly, so this is the test-only counterpart to that.
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
async function deployBuild(port, admin, { platform = 'mac', filename, contents, winText = '', quizQuestions = TEST_QUIZ_QUESTIONS, iqSkipOfferDisabled = false } = {}) {
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

    const ackMsg = await conn.waitFor((m) => m.payload === 'distRegisterAck');
    const uploadToken = ackMsg.distRegisterAck.uploadToken;

    await httpUpload({ host: 'localhost', port, token: uploadToken, filename: finalFilename, contents: finalContents });

    conn.send({ distComplete: { uuid, filename: finalFilename, winText, quizQuestions, iqSkipOfferDisabled } });
    await conn.waitFor((m) => m.payload === 'distCompleteAck');
    await conn.close();

    return { uuid, filename: finalFilename, platform, contents: finalContents, winText, quizQuestions, iqSkipOfferDisabled };
}

// Full distRegister -> admin auth -> HTTPS upload -> distReplaceComplete cycle, mirroring
// deployBuild but carrying forward oldUuid's state (see ClientDistReplaceComplete in
// src/Server.elm) instead of starting fresh. quizQuestions/winText are NOT carried forward
// from oldUuid -- they're resent fresh on every replace (see #77), so they default the same
// way deployBuild's do rather than being read from oldUuid's build.
async function replaceBuild(port, admin, oldUuid, { platform = 'mac', filename, contents, winText = '', quizQuestions = TEST_QUIZ_QUESTIONS, iqSkipOfferDisabled = false } = {}) {
    const uuid = crypto.randomUUID();
    const finalFilename = filename || `test-build-${uuid}.bin`;
    const finalContents = contents !== undefined ? contents : Buffer.from(`dummy build ${uuid}`);

    const conn = await connect(port);
    conn.send({ distRegister: { uuid, platform } });
    const authResult = await admin.respondToChallenge(conn);
    if (!authResult.success) {
        await conn.closed();
        throw new Error(`admin auth failed while replacing (level=${authResult.level})`);
    }

    const ackMsg = await conn.waitFor((m) => m.payload === 'distRegisterAck');
    const uploadToken = ackMsg.distRegisterAck.uploadToken;

    await httpUpload({ host: 'localhost', port, token: uploadToken, filename: finalFilename, contents: finalContents });

    conn.send({ distReplaceComplete: { newUuid: uuid, oldUuid, filename: finalFilename, winText, quizQuestions, iqSkipOfferDisabled } });
    await conn.waitFor((m) => m.payload === 'distReplaceCompleteAck');
    await conn.close();

    return { uuid, filename: finalFilename, platform, contents: finalContents, winText, quizQuestions, iqSkipOfferDisabled };
}

async function undeploy(port, admin, uuid) {
    const conn = await connect(port);
    conn.send({ distUndeploy: { uuid } });
    const authResult = await admin.respondToChallenge(conn);
    if (!authResult.success) {
        await conn.closed();
        return { authResult, ack: null };
    }
    const ackMsg = await conn.waitFor((m) => m.payload === 'distUndeployAck');
    return { authResult, ack: ackMsg.distUndeployAck };
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
// requestStateEdit. Resolves to either a `distStateEditSaveAck` (saved) or
// `stateRequestRejected` (invalid JSON — server leaves the previous state untouched).
async function saveStateEdit(conn, uuid, json) {
    conn.send({ distStateEditSave: { uuid, json } });
    return conn.waitFor((m) => m.payload === 'distStateEditSaveAck' || m.payload === 'stateRequestRejected');
}

module.exports = { deployBuild, replaceBuild, undeploy, listBuilds, requestStateEdit, saveStateEdit, download };
