const crypto = require('crypto');
const { _internals } = require('../server/auth.js');

const AUTH_LEVEL_ADMIN = 2;

function validateCredentials({ username, password }) {
    return !!username && !!password;
}

function buildAdminRow(username, password, salt, hashFn) {
    const hash = hashFn(password, salt);
    return { username, salt, hash, level: AUTH_LEVEL_ADMIN };
}

module.exports = { validateCredentials, buildAdminRow };

if (require.main === module) {
    async function main() {
        const { username, password } = await _internals.promptCredentials();
        if (!validateCredentials({ username, password })) {
            console.error('Username and password are required.');
            process.exit(1);
        }

        const salt = crypto.randomBytes(16).toString('hex');
        const row = buildAdminRow(username, password, salt, _internals.hashPassword);

        _internals.appendJsonRow(_internals.USERS_FILE, 'users', row);

        console.log(`Added admin user '${username}' to ${_internals.USERS_FILE}`);
    }

    main().catch((err) => {
        console.error(err);
        process.exit(1);
    });
}
