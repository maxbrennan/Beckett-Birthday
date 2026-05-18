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
const KEYS_DIR = path.join(CLIENT_DIR, 'keys');
const UUID_ENV_FILE = path.join(CLIENT_DIR, 'uuid.env');

const AUTH_LEVEL_NAME = { 0: 'none', 1: 'player', 2: 'admin' };

// === Public API ===

function generateAuthChallenge() {
    return {
        challenge: crypto.randomBytes(32),
        level: CHALLENGE_LEVEL,
    };
}

async function handleAuthChallenge(challengeMsg) {
    const level = challengeMsg.level;
    const challenge = toBuffer(challengeMsg.challenge);

    if (hasKeys(level)) {
        const privateKeyPem = fs.readFileSync(privateKeyPath(level), 'utf8');
        const signature = signWithKey(privateKeyPem, challenge);
        return {
            key: {
                uuid: process.env.AUTH_UUID || '',
                challengeResponse: signature,
            },
        };
    }

    const { username, password } = await promptCredentials();
    const { publicKeyPem } = loadOrGenerateKeys(level);
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
            const publicKeyPem = Buffer.from(publicKey).toString('utf8');
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

function handleAuthResult(resultMsg) {
    switch (resultMsg.result) {
        case 'password': {
            const r = resultMsg.password;
            if (r.success) {
                console.log(`Auth ok (${AUTH_LEVEL_NAME[r.level]}). UUID: ${r.uuid}`);
                persistUuid(r.uuid);
            } else {
                console.log('Auth failed.');
            }
            return;
        }
        case 'key': {
            const r = resultMsg.key;
            if (r.success) console.log(`Auth ok (${AUTH_LEVEL_NAME[r.level]}).`);
            else console.log('Auth failed.');
            return;
        }
        default:
            console.log('Auth failed (unknown result variant).');
    }
}

// === Internal helpers ===

function toBuffer(maybe) {
    if (Buffer.isBuffer(maybe)) return maybe;
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

function privateKeyPath(level) {
    return path.join(KEYS_DIR, `${AUTH_LEVEL_NAME[level]}.pem`);
}

function publicKeyPath(level) {
    return path.join(KEYS_DIR, `${AUTH_LEVEL_NAME[level]}.pub.pem`);
}

function hasKeys(level) {
    return fs.existsSync(privateKeyPath(level)) && fs.existsSync(publicKeyPath(level));
}

function loadOrGenerateKeys(level) {
    if (hasKeys(level)) {
        return {
            publicKeyPem: fs.readFileSync(publicKeyPath(level), 'utf8'),
            privateKeyPem: fs.readFileSync(privateKeyPath(level), 'utf8'),
            isNew: false,
        };
    }
    ensureDir(KEYS_DIR);
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
    const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
    fs.writeFileSync(privateKeyPath(level), privateKeyPem, { mode: 0o600 });
    fs.writeFileSync(publicKeyPath(level), publicKeyPem);
    return { publicKeyPem, privateKeyPem, isNew: true };
}

function signWithKey(privateKeyPem, data) {
    return crypto.sign(null, data, privateKeyPem);
}

function promptCredentials() {
    return new Promise((resolve) => {
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        rl.question('Username: ', (username) => {
            const stdout = process.stdout;
            const origWrite = stdout.write.bind(stdout);
            stdout.write = (chunk, encoding, cb) => {
                if (typeof chunk === 'string' && chunk !== '\n' && chunk !== '\r\n') {
                    return origWrite('', encoding, cb);
                }
                return origWrite(chunk, encoding, cb);
            };
            rl.question('Password: ', (password) => {
                stdout.write = origWrite;
                origWrite('\n');
                rl.close();
                resolve({ username: username.trim(), password });
            });
        });
    });
}

function persistUuid(uuid) {
    ensureDir(CLIENT_DIR);
    fs.writeFileSync(UUID_ENV_FILE, `AUTH_UUID=${uuid}\n`);
    process.env.AUTH_UUID = uuid;
}

function loadStoredUuid() {
    if (!fs.existsSync(UUID_ENV_FILE)) return null;
    const line = fs.readFileSync(UUID_ENV_FILE, 'utf8').trim();
    const match = line.match(/^AUTH_UUID=(.*)$/);
    if (!match) return null;
    process.env.AUTH_UUID = match[1];
    return match[1];
}

loadStoredUuid();

module.exports = {
    generateAuthChallenge,
    handleAuthChallenge,
    handleAuthResponse,
    handleAuthResult,
    // Exposed for fixtures / testing only:
    _internals: { hashPassword, loadOrGenerateKeys, persistUuid, loadStoredUuid },
};
