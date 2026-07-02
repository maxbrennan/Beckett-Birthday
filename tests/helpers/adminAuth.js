'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const auth = require('../../server/auth.js');

// Drives the real client-side challenge/response functions in server/auth.js — the same
// handleAuthChallenge/handleAuthResult scripts/deploy.js and scripts/add-admin.js use —
// against an isolated temp keys directory and injected credentials, instead of the real
// ~/.birthday-auth and an interactive stdin prompt. This validates the *server's*
// signature verification/challenge gating/fallback logic using the real client logic on
// both ends of the wire.
class AdminClient {
    constructor({ username, password, keysDir } = {}) {
        this.username = username;
        this.password = password;
        this.clientDir = keysDir || fs.mkdtempSync(path.join(os.tmpdir(), 'beckett-admin-keys-'));
        // Independent identity state per AdminClient instance — see server/auth.js's
        // _defaultSession comment for why this can't just be the module-level default.
        this.session = { keyAuthFailed: false, uuid: null };
    }

    get privateKeyPath() { return auth._internals.privateKeyPath(2, this.clientDir); }
    get publicKeyPath() { return auth._internals.publicKeyPath(2, this.clientDir); }

    // Simulates the stored private key file being tampered with / replaced: swaps in an
    // unrelated, syntactically valid Ed25519 key the server has never seen. Signing still
    // succeeds locally, but the server's verification against the *registered* public key
    // for this uuid correctly fails — a clean "wrong key" rejection, not a local crash.
    corruptKey() {
        const { privateKey } = crypto.generateKeyPairSync('ed25519');
        fs.writeFileSync(this.privateKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    }

    deleteKey() {
        fs.rmSync(this.privateKeyPath, { force: true });
        fs.rmSync(this.publicKeyPath, { force: true });
    }

    // Drives exactly one challenge -> response -> result cycle on an already-open `conn`
    // (a tests/helpers/protocolClient.js instance). The caller must have already sent
    // whatever message triggers the server's authChallenge (distRegister/distUndeploy/
    // distList/distStateEdit) on this same `conn` before calling this. On a failed
    // attempt the server closes `conn` (matching every admin-gated path in
    // server/index.js and src/Server.elm's AuthCompleted) — reconnecting and retrying,
    // if desired, is left to the caller so tests demonstrate that behavior explicitly.
    //
    // `preferKey: false` forces the password path (via auth.js's forcePassword option)
    // even if a usable stored key exists, so tests can exercise password auth on demand.
    async respondToChallenge(conn, { preferKey = true } = {}) {
        const challengeMsg = await conn.waitFor((m) => m.payload === 'authChallenge');

        const response = await auth.handleAuthChallenge(challengeMsg.authChallenge, {
            clientDir: this.clientDir,
            session: this.session,
            forcePassword: !preferKey,
            credentials: async () => ({ username: this.username, password: this.password }),
        });
        conn.send({ authResponse: response });

        const resultMsg = await conn.waitFor((m) => m.payload === 'authResult');
        auth.handleAuthResult(resultMsg.authResult, { clientDir: this.clientDir, session: this.session });

        const method = resultMsg.authResult.password ? 'password' : 'key';
        const variant = resultMsg.authResult[method];

        return {
            method,
            success: !!variant.success,
            level: variant.level || 0,
            uuid: variant.uuid || this.session.uuid || '',
            requestedLevel: challengeMsg.authChallenge.level,
        };
    }
}

module.exports = { AdminClient };
