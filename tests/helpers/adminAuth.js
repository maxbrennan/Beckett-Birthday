'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

// A self-contained reference "admin CLI" test double for the challenge/response auth
// flow in server/auth.js. Deliberately does NOT reuse server/auth.js's own client-side
// functions (handleAuthChallenge/promptCredentials/loadOrGenerateKeys) — those persist
// keys under the real ~/.birthday-auth on whatever machine runs the tests and block on
// interactive stdin, neither of which is appropriate here. This class independently
// implements the same wire behavior, scoped to a temp keys directory it owns, so tests
// validate the *server's* signature verification/challenge gating/fallback logic without
// touching real developer/CI-runner credentials.
class AdminClient {
    constructor({ username, password, keysDir } = {}) {
        this.username = username;
        this.password = password;
        this.keysDir = keysDir || fs.mkdtempSync(path.join(os.tmpdir(), 'beckett-admin-keys-'));
        fs.mkdirSync(this.keysDir, { recursive: true });
        // Set once a password auth succeeds and the server mints/registers a uuid for
        // the public key we sent. Key auth is only attempted once this is set, mirroring
        // the real client's "no identity to sign in as until password auth succeeds" rule.
        this.uuid = null;
    }

    get privateKeyPath() { return path.join(this.keysDir, 'admin.pem'); }
    get publicKeyPath() { return path.join(this.keysDir, 'admin.pub.pem'); }

    hasUsableKey() {
        return !!this.uuid && fs.existsSync(this.privateKeyPath) && fs.existsSync(this.publicKeyPath);
    }

    generateKeypair() {
        const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
        const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
        const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
        fs.writeFileSync(this.privateKeyPath, privateKeyPem, { mode: 0o600 });
        fs.writeFileSync(this.publicKeyPath, publicKeyPem);
        return { publicKeyPem, privateKeyPem };
    }

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
    async respondToChallenge(conn, { preferKey = true } = {}) {
        const challengeMsg = await conn.waitFor((m) => m.payload === 'authChallenge');
        const { challenge, level } = challengeMsg.authChallenge;
        const useKey = preferKey && this.hasUsableKey();

        if (useKey) {
            const privateKeyPem = fs.readFileSync(this.privateKeyPath, 'utf8');
            const challengeBuf = Buffer.from(challenge, 'base64');
            const signature = crypto.sign(null, challengeBuf, privateKeyPem);
            conn.send({ authResponse: { key: { uuid: this.uuid, challengeResponse: signature } } });
        } else {
            if (!fs.existsSync(this.privateKeyPath) || !fs.existsSync(this.publicKeyPath)) {
                this.generateKeypair();
            }
            const publicKeyPem = fs.readFileSync(this.publicKeyPath, 'utf8');
            conn.send({
                authResponse: {
                    password: {
                        username: this.username,
                        password: this.password,
                        publicKey: Buffer.from(publicKeyPem, 'utf8'),
                    },
                },
            });
        }

        const resultMsg = await conn.waitFor((m) => m.payload === 'authResult');
        const method = resultMsg.authResult.password ? 'password' : 'key';
        const variant = resultMsg.authResult[method];

        if (method === 'password' && variant.success) {
            this.uuid = variant.uuid;
        }

        return {
            method,
            success: !!variant.success,
            level: variant.level || 0,
            uuid: variant.uuid || this.uuid || '',
            requestedLevel: level,
        };
    }
}

module.exports = { AdminClient };
