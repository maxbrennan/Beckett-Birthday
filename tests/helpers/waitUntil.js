'use strict';

// The server acks a protocol operation (distComplete/distUndeploy/distStateEditSave)
// over the WebSocket as soon as it dispatches the corresponding Cmd.batch in
// src/Server.elm — but that batch's writeFile/registry write and its sendToClient ack
// aren't sequenced relative to each other, so the ack can arrive slightly before the
// write actually lands on disk. Tests that read app-builds/builds.jsonl right after an
// ack should poll for the expected state rather than assume it's already there.
async function waitUntil(predicateFn, { timeoutMs = 2000, intervalMs = 20 } = {}) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const result = predicateFn();
        if (result) return result;
        if (Date.now() > deadline) {
            throw new Error(`waitUntil: timed out after ${timeoutMs}ms waiting for condition`);
        }
        await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
}

module.exports = { waitUntil };
