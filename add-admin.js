const crypto = require('crypto');
const fs = require('fs');
const { _internals } = require('./auth-helpers.js');

const AUTH_LEVEL_ADMIN = 2;

async function main() {
    const { username, password } = await _internals.promptCredentials();
    if (!username || !password) {
        console.error('Username and password are required.');
        process.exit(1);
    }

    const salt = crypto.randomBytes(16).toString('hex');
    const hash = _internals.hashPassword(password, salt);
    const row = { username, salt, hash, level: AUTH_LEVEL_ADMIN };

    fs.mkdirSync(_internals.SERVER_DIR, { recursive: true });
    fs.appendFileSync(_internals.USERS_FILE, JSON.stringify(row) + '\n');

    console.log(`Added admin user '${username}' to ${_internals.USERS_FILE}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
