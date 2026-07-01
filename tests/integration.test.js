'use strict';

const { spawn, execSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

const PROJECT_ROOT = path.join(__dirname, '..');
const SERVER_SCRIPT = path.join(PROJECT_ROOT, 'server', 'index.js');
const ELM_SERVER_JS = path.join(PROJECT_ROOT, 'elm-server.js');
const CERTS_DIR = path.join(PROJECT_ROOT, 'certs');
const CERT_FILE = path.join(CERTS_DIR, 'cert.pem');
const KEY_FILE = path.join(CERTS_DIR, 'key.pem');
const TEST_PORT = 19443;

let child;
let tempDir;
let generatedCerts = false;

describe('integration', () => {
    beforeAll(async () => {
        if (!fs.existsSync(ELM_SERVER_JS)) {
            throw new Error('elm-server.js not found — run: npm run build:server');
        }

        // certs/ is gitignored; generate a temporary self-signed cert if not already present.
        // Avoid overwriting certs that may be in use by the dev server.
        if (!fs.existsSync(CERT_FILE) || !fs.existsSync(KEY_FILE)) {
            execSync(
                'openssl req -x509 -newkey rsa:2048 ' +
                `-keyout "${KEY_FILE}" -out "${CERT_FILE}" ` +
                '-days 1 -nodes -subj "/CN=localhost"',
                { stdio: 'pipe', timeout: 30000 }
            );
            generatedCerts = true;
        }

        // Isolated cwd so .auth/ (resolved via process.cwd() in auth.js) doesn't pollute the project
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'beckett-test-'));

        // Seed a test admin — inline the scrypt hash to avoid importing auth.js,
        // which has a side-effectful loadStoredUuid() call at module level.
        const saltHex = crypto.randomBytes(16).toString('hex');
        const hash = crypto.scryptSync('testpassword', Buffer.from(saltHex, 'hex'), 64).toString('hex');
        const row = { username: 'testadmin', salt: saltHex, hash, level: 2 };
        fs.mkdirSync(path.join(tempDir, '.auth'), { recursive: true });
        fs.writeFileSync(path.join(tempDir, '.auth', 'users.jsonl'), JSON.stringify(row) + '\n');

        child = spawn(process.execPath, [SERVER_SCRIPT], {
            cwd: tempDir,
            // Spread parent env so PATH, HOME, etc. are inherited; override port/mode.
            // dotenv (loaded inside server/index.js) does not override existing env vars,
            // so these values win over whatever is in the .env file.
            env: { ...process.env, DEV: 'true', DEV_SERVER_PORT: String(TEST_PORT) },
        });

        await new Promise((resolve, reject) => {
            let stdoutBuf = '';
            let stderrBuf = '';
            const timer = setTimeout(
                () => reject(new Error(`Server start timed out after 15s.\nstderr:\n${stderrBuf}`)),
                15000
            );

            child.stdout.on('data', (chunk) => {
                stdoutBuf += chunk.toString();
                if (stdoutBuf.includes(`WebSocket server listening on port ${TEST_PORT}`)) {
                    clearTimeout(timer);
                    resolve();
                }
            });
            child.stderr.on('data', (chunk) => { stderrBuf += chunk.toString(); });

            // once() so the listener doesn't linger after server is up and fire again during teardown
            child.once('error', (err) => { clearTimeout(timer); reject(err); });
            child.once('exit', (code, signal) => {
                clearTimeout(timer);
                reject(new Error(
                    `Server exited unexpectedly (code=${code}, signal=${signal}).\nstderr:\n${stderrBuf}`
                ));
            });
        });
    }, 20000);

    afterAll(async () => {
        // child.exitCode is null while the process is still running; skip kill if already dead
        if (child && child.exitCode === null) {
            await new Promise((resolve) => {
                // Escalate to SIGKILL after 5s; resolve regardless so after() always completes
                const killTimer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 5000);
                child.once('exit', () => { clearTimeout(killTimer); resolve(); });
                child.kill('SIGTERM');
            });
        }
        if (tempDir) {
            fs.rmSync(tempDir, { recursive: true, force: true });
        }
        // Only remove certs we generated; don't delete pre-existing dev certs
        if (generatedCerts) {
            for (const f of [CERT_FILE, KEY_FILE]) {
                try { fs.rmSync(f); } catch (_) {}
            }
        }
    }, 10000);

    test('server accepts WebSocket connections', async () => {
        // rejectUnauthorized: false required for the self-signed certs
        const ws = new WebSocket(`wss://localhost:${TEST_PORT}`, { rejectUnauthorized: false });
        await new Promise((resolve, reject) => {
            ws.on('open', resolve);
            ws.on('error', reject);
        });
        ws.close();
        await new Promise((resolve) => ws.on('close', resolve));
    }, 10000);
});
