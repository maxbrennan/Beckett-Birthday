const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');

// Hardcoded for now; admin commands are the only consumer. Mirror of
// AuthLevel in proto/messages.proto. Change here when player auth lands.
const CHALLENGE_LEVEL = 2; // AUTH_LEVEL_ADMIN
const AUTH_LEVEL_NONE = 0;

const SERVER_DIR = path.join(process.cwd(), '.auth');
const USERS_FILE = path.join(SERVER_DIR, 'users.jsonl');
const UUIDS_FILE = path.join(SERVER_DIR, 'uuids.jsonl');

const CLIENT_DIR = path.join(os.homedir(), '.birthday-auth');

const AUTH_LEVEL_NAME = { 0: 'none', 1: 'player', 2: 'admin' };

// Default session for the real CLI clients (scripts/deploy.js, scripts/add-admin.js):
// a single process acting as one identity, so module-level state is fine. Callers that
// need multiple independent identities in one process (tests driving several admin
// clients) pass their own `session` object instead of relying on this one.
const _defaultSession = { keyAuthFailed: false, uuid: null };

// === Public API ===

function isAdminAuth(variant) {
    return !!variant.success && (variant.level || 0) >= 2;
}

function generateAuthChallenge() {
    return {
        challenge: crypto.randomBytes(32),
        level: CHALLENGE_LEVEL,
    };
}

// `opts.clientDir` overrides where keys/uuid are stored (defaults to the real
// ~/.birthday-auth); `opts.credentials` overrides the interactive username/password
// prompt; `opts.session` overrides the module-level identity state; `opts.forcePassword`
// skips a usable stored key even if one exists. All default to the real CLI behavior so
// scripts/deploy.js and scripts/add-admin.js are unaffected when called with no opts.
async function handleAuthChallenge(challengeMsg, opts = {}) {
    const {
        clientDir = CLIENT_DIR,
        credentials = promptCredentials,
        session = _defaultSession,
        forcePassword = false,
    } = opts;
    const level = challengeMsg.level;
    const challenge = toBuffer(challengeMsg.challenge);

    if (!forcePassword && hasKeys(level, clientDir) && !session.keyAuthFailed) {
        const privateKeyPem = fs.readFileSync(privateKeyPath(level, clientDir), 'utf8');
        const signature = signWithKey(privateKeyPem, challenge);
        return {
            key: {
                uuid: session.uuid || process.env.AUTH_UUID || '',
                challengeResponse: signature,
            },
        };
    }

    const { username, password } = await credentials();
    // Force-generate new keys when retrying after key failure so the stale
    // keypair is overwritten and the fresh public key is registered with the server.
    const { publicKeyPem } = session.keyAuthFailed
        ? generateNewKeys(level, clientDir)
        : loadOrGenerateKeys(level, clientDir);
    return {
        password: {
            username,
            password,
            publicKey: Buffer.from(publicKeyPem, 'utf8'),
        },
    };
}

function handleAuthResponse(responseMsg, originalChallenge) {
    const challenge = toBuffer(originalChallenge);

    switch (responseMsg.method) {
        case 'password': {
            const { username, password, publicKey } = responseMsg.password;
            const publicKeyPem = toBuffer(publicKey).toString('utf8');
            const user = findUser(username);
            if (!user || !verifyPassword(password, user.salt, user.hash)) {
                return { password: { success: false, level: AUTH_LEVEL_NONE, uuid: '' } };
            }
            const uuid = crypto.randomUUID();
            appendUuid({ uuid, public_key_pem: publicKeyPem, level: user.level });
            return { password: { success: true, level: user.level, uuid } };
        }
        case 'key': {
            const { uuid, challengeResponse } = responseMsg.key;
            const row = findUuidRow(uuid);
            if (!row) return { key: { success: false, level: AUTH_LEVEL_NONE } };
            const ok = verifyWithKey(row.public_key_pem, challenge, toBuffer(challengeResponse));
            return { key: { success: ok, level: ok ? row.level : AUTH_LEVEL_NONE } };
        }
        default:
            return { key: { success: false, level: AUTH_LEVEL_NONE } };
    }
}

// Returns { needsRetry: boolean }. Callers must re-run the full challenge/response
// cycle (including fetching a fresh challenge) when needsRetry is true.
function handleAuthResult(resultMsg, opts = {}) {
    const { clientDir = CLIENT_DIR, session = _defaultSession } = opts;
    switch (resultMsg.result) {
        case 'password': {
            const r = resultMsg.password;
            if (r.success) {
                console.log(`Auth ok (${AUTH_LEVEL_NAME[r.level]}). UUID: ${r.uuid}`);
                session.uuid = r.uuid;
                persistUuid(r.uuid, clientDir);
                session.keyAuthFailed = false;
            } else {
                console.log('Auth failed.');
            }
            break;
        }
        case 'key': {
            const r = resultMsg.key;
            if (r.success) {
                console.log(`Auth ok (${AUTH_LEVEL_NAME[r.level]}).`);
            } else {
                console.log('Key auth failed, retrying with password.');
                session.keyAuthFailed = true;
            }
            break;
        }
        default:
            console.log('Auth failed (unknown result variant).');
    }
}

// === Internal helpers ===

function toBuffer(maybe) {
    if (Buffer.isBuffer(maybe)) return maybe;
    if (maybe instanceof Uint8Array) return Buffer.from(maybe);
    if (typeof maybe === 'string') return Buffer.from(maybe, 'base64');
    return Buffer.from(maybe);
}

function ensureDir(dir) {
    fs.mkdirSync(dir, { recursive: true });
}

// Server-side

function findUser(username) {
    if (!fs.existsSync(USERS_FILE)) return null;
    const lines = fs.readFileSync(USERS_FILE, 'utf8').split('\n').filter(Boolean);
    for (const line of lines) {
        const row = JSON.parse(line);
        if (row.username === username) return row;
    }
    return null;
}

function appendUuid(row) {
    ensureDir(SERVER_DIR);
    fs.appendFileSync(UUIDS_FILE, JSON.stringify(row) + '\n');
}

function findUuidRow(uuid) {
    if (!uuid || !fs.existsSync(UUIDS_FILE)) return null;
    const lines = fs.readFileSync(UUIDS_FILE, 'utf8').split('\n').filter(Boolean);
    for (const line of lines) {
        const row = JSON.parse(line);
        if (row.uuid === uuid) return row;
    }
    return null;
}

function hashPassword(password, saltHex) {
    return crypto.scryptSync(password, Buffer.from(saltHex, 'hex'), 64).toString('hex');
}

function verifyPassword(password, saltHex, expectedHashHex) {
    const computed = hashPassword(password, saltHex);
    const a = Buffer.from(computed, 'hex');
    const b = Buffer.from(expectedHashHex, 'hex');
    return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function verifyWithKey(publicKeyPem, data, signature) {
    try {
        return crypto.verify(null, data, publicKeyPem, signature);
    } catch (_) {
        return false;
    }
}

// Client-side

function keysDir(clientDir) {
    return path.join(clientDir, 'keys');
}

function privateKeyPath(level, clientDir = CLIENT_DIR) {
    return path.join(keysDir(clientDir), `${AUTH_LEVEL_NAME[level]}.pem`);
}

function publicKeyPath(level, clientDir = CLIENT_DIR) {
    return path.join(keysDir(clientDir), `${AUTH_LEVEL_NAME[level]}.pub.pem`);
}

function hasKeys(level, clientDir = CLIENT_DIR) {
    return fs.existsSync(privateKeyPath(level, clientDir)) && fs.existsSync(publicKeyPath(level, clientDir));
}

function generateNewKeys(level, clientDir = CLIENT_DIR) {
    ensureDir(keysDir(clientDir));
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
    const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
    fs.writeFileSync(privateKeyPath(level, clientDir), privateKeyPem, { mode: 0o600 });
    fs.writeFileSync(publicKeyPath(level, clientDir), publicKeyPem);
    return { publicKeyPem, privateKeyPem };
}

function loadOrGenerateKeys(level, clientDir = CLIENT_DIR) {
    if (hasKeys(level, clientDir)) {
        return {
            publicKeyPem: fs.readFileSync(publicKeyPath(level, clientDir), 'utf8'),
            privateKeyPem: fs.readFileSync(privateKeyPath(level, clientDir), 'utf8'),
            isNew: false,
        };
    }
    ensureDir(keysDir(clientDir));
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
    const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
    fs.writeFileSync(privateKeyPath(level, clientDir), privateKeyPem, { mode: 0o600 });
    fs.writeFileSync(publicKeyPath(level, clientDir), publicKeyPem);
    return { publicKeyPem, privateKeyPem, isNew: true };
}

function signWithKey(privateKeyPem, data) {
    return crypto.sign(null, data, privateKeyPem);
}

function promptCredentials() {
    return new Promise((resolve) => {
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        let muted = false;
        rl._writeToOutput = (s) => {
            if (!muted) rl.output.write(s);
        };
        rl.question('Username: ', (username) => {
            rl.question('Password: ', (password) => {
                muted = false;
                rl.output.write('\n');
                rl.close();
                resolve({ username: username.trim(), password });
            });
            muted = true;
        });
    });
}

function uuidEnvFile(clientDir) {
    return path.join(clientDir, 'uuid.env');
}

// Only mutates the process-wide AUTH_UUID env var for the real ~/.birthday-auth
// identity; a test-provided clientDir just gets its own uuid.env file, so multiple
// AdminClient identities in one process don't stomp on each other's env state (each
// tracks its own uuid via its `session` object instead).
function persistUuid(uuid, clientDir = CLIENT_DIR) {
    ensureDir(clientDir);
    fs.writeFileSync(uuidEnvFile(clientDir), `AUTH_UUID=${uuid}\n`);
    if (clientDir === CLIENT_DIR) process.env.AUTH_UUID = uuid;
}

function loadStoredUuid(clientDir = CLIENT_DIR) {
    if (!fs.existsSync(uuidEnvFile(clientDir))) return null;
    const line = fs.readFileSync(uuidEnvFile(clientDir), 'utf8').trim();
    const match = line.match(/^AUTH_UUID=(.*)$/);
    if (!match) return null;
    if (clientDir === CLIENT_DIR) process.env.AUTH_UUID = match[1];
    return match[1];
}

loadStoredUuid();

module.exports = {
    isAdminAuth,
    generateAuthChallenge,
    handleAuthChallenge,
    handleAuthResponse,
    handleAuthResult,
    // Exposed for fixtures / scripts:
    _internals: {
        hashPassword,
        loadOrGenerateKeys,
        persistUuid,
        loadStoredUuid,
        promptCredentials,
        privateKeyPath,
        publicKeyPath,
        hasKeys,
        USERS_FILE,
        SERVER_DIR,
        CLIENT_DIR,
    },
};
