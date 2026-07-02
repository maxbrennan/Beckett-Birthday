'use strict';

const { connect } = require('./protocolClient');

// Connects as a "player" (i.e. a real client, not an admin) for a given uuid — sends a
// stateRequest and resolves once the server responds, whether that's a successful
// stateUpdate or a stateRequestRejected. The returned `conn` stays open so callers can
// later observe a server-initiated kick via `conn.closed()`.
async function connectAsPlayer(port, uuid) {
    const conn = await connect(port);
    conn.send({ stateRequest: { uuid } });
    const result = await conn.waitFor((m) => m.payload === 'stateUpdate' || m.payload === 'stateRequestRejected');
    return { conn, result };
}

module.exports = { connectAsPlayer };
