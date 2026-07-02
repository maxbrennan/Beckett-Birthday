'use strict';

const fs = require('fs');
const path = require('path');
const { CERT_FILE, KEY_FILE } = require('./certPaths');

const MARKER = path.join(__dirname, '.generated-certs-marker');

module.exports = async function globalTeardown() {
    if (fs.existsSync(MARKER)) {
        for (const f of [CERT_FILE, KEY_FILE]) {
            try { fs.rmSync(f); } catch (_) {}
        }
        try { fs.rmSync(MARKER); } catch (_) {}
    }
};
