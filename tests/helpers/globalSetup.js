'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { CERT_FILE, KEY_FILE } = require('./certPaths');

// Runs once for the whole Jest run (not per worker), so the self-signed cert
// used by every spawned test server is generated exactly once instead of racing
// across parallel test files. Leaves a pre-existing dev cert untouched.
const MARKER = path.join(__dirname, '.generated-certs-marker');

module.exports = async function globalSetup() {
    if (!fs.existsSync(CERT_FILE) || !fs.existsSync(KEY_FILE)) {
        execSync(
            'openssl req -x509 -newkey rsa:2048 ' +
            `-keyout "${KEY_FILE}" -out "${CERT_FILE}" ` +
            '-days 1 -nodes -subj "/CN=localhost"',
            { stdio: 'pipe', timeout: 30000 }
        );
        fs.writeFileSync(MARKER, '1');
    }
};
