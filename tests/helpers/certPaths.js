'use strict';

const path = require('path');

const PROJECT_ROOT = path.join(__dirname, '..', '..');
const CERTS_DIR = path.join(PROJECT_ROOT, 'certs');
const CERT_FILE = path.join(CERTS_DIR, 'cert.pem');
const KEY_FILE = path.join(CERTS_DIR, 'key.pem');

module.exports = { PROJECT_ROOT, CERTS_DIR, CERT_FILE, KEY_FILE };
