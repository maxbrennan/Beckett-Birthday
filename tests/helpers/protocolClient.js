'use strict';

const WebSocket = require('ws');
const codec = require('../../server/codec.js');

// Thin ws + protobuf wrapper used by the integration tests to talk to a real
// server/index.js instance without hand-rolling WebSocket plumbing per test file.
async function connect(port) {
    const ws = new WebSocket(`wss://localhost:${port}`, { rejectUnauthorized: false });

    const pending = []; // decoded messages not yet claimed by a waitFor call
    const waiters = []; // { predicate, resolve, reject, timer }
    let isClosed = false;

    ws.on('message', (data) => {
        let msg;
        try {
            msg = codec.decodeServer(data);
        } catch (err) {
            return;
        }
        const idx = waiters.findIndex((w) => w.predicate(msg));
        if (idx !== -1) {
            const [w] = waiters.splice(idx, 1);
            clearTimeout(w.timer);
            w.resolve(msg);
        } else {
            pending.push(msg);
        }
    });

    ws.on('close', () => {
        isClosed = true;
        while (waiters.length) {
            const w = waiters.shift();
            clearTimeout(w.timer);
            w.reject(new Error('connection closed while waiting for message'));
        }
    });

    await new Promise((resolve, reject) => {
        ws.once('open', resolve);
        ws.once('error', reject);
    });

    function send(payload) {
        ws.send(codec.encodeClient(payload), { binary: true });
    }

    // predicate: (decodedServerMessage) => boolean. Resolves with the first matching
    // message, whether it already arrived (buffered in `pending`) or arrives later.
    function waitFor(predicate, timeoutMs = 5000) {
        const idx = pending.findIndex(predicate);
        if (idx !== -1) {
            const [msg] = pending.splice(idx, 1);
            return Promise.resolve(msg);
        }
        if (isClosed) return Promise.reject(new Error('connection already closed'));
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                const i = waiters.findIndex((w) => w.resolve === resolve);
                if (i !== -1) waiters.splice(i, 1);
                reject(new Error(`timed out after ${timeoutMs}ms waiting for message`));
            }, timeoutMs);
            waiters.push({ predicate, resolve, reject, timer });
        });
    }

    function closed() {
        if (isClosed) return Promise.resolve();
        return new Promise((resolve) => ws.once('close', resolve));
    }

    function close() {
        if (ws.readyState === WebSocket.CLOSED) return Promise.resolve();
        ws.close();
        return closed();
    }

    return { ws, send, waitFor, closed, close };
}

module.exports = { connect };
