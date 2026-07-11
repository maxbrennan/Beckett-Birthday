// Shared helpers for the admin CLI scripts (edit-state.js, undeploy.js) that all connect
// to the prod server over WebSocket and drive the same key/password auth-retry loop.

function computeServerUrl(env) {
    const host = env.PROD_SERVER_HOST;
    const port = env.PROD_SERVER_PORT || '443';
    return port === '443' ? `wss://${host}` : `wss://${host}:${port}`;
}

function createMessageQueue() {
    let pendingResolver = null;
    const incoming = [];

    const nextMessage = () => new Promise((resolve) => {
        if (incoming.length > 0) resolve(incoming.shift());
        else pendingResolver = resolve;
    });

    function pushMessage(msg) {
        if (pendingResolver) { const r = pendingResolver; pendingResolver = null; r(msg); }
        else incoming.push(msg);
    }

    return { nextMessage, pushMessage };
}

// Attach message + close handlers to a socket so both feed the same queue.
// Injects a synthetic _closed sentinel so the auth loop can detect disconnects.
function wireSocket(socket, { codec, pushMessage, tag }) {
    socket.on('message', (data) => {
        let msg;
        try { msg = codec.decodeServer(data); }
        catch (err) { console.error(`[${tag}] decode error:`, err.message); return; }
        pushMessage(msg);
    });
    socket.on('close', () => pushMessage({ payload: '_closed' }));
}

// Pure classification of an authResult payload's outcome, shared by every CLI script's
// auth-retry loop: key-auth failure vs password failure vs success look the same to the
// caller (the field name is just `key` or `password`).
function classifyAuthResult(authResult) {
    const variant = authResult.password || authResult.key || {};
    const isKeyFailure = !!(authResult.key && !authResult.key.success);
    return { success: !!variant.success, isKeyFailure };
}

function formatBuildListLine(entry) {
    return `  ${entry.uuid}  ${entry.filename}  (${entry.platform})`;
}

module.exports = { computeServerUrl, createMessageQueue, wireSocket, classifyAuthResult, formatBuildListLine };
