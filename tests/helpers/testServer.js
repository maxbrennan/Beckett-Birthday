'use strict';

const { spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { PROJECT_ROOT } = require('./certPaths');

const SERVER_SCRIPT = path.join(PROJECT_ROOT, 'server', 'index.js');
const ELM_SERVER_JS = path.join(PROJECT_ROOT, 'elm-server.js');

function seedUser(authDir, { username, password, level }) {
    const saltHex = crypto.randomBytes(16).toString('hex');
    const hash = crypto.scryptSync(password, Buffer.from(saltHex, 'hex'), 64).toString('hex');
    const row = { username, salt: saltHex, hash, level };
    fs.appendFileSync(path.join(authDir, 'users.jsonl'), JSON.stringify(row) + '\n');
}

// Spawns a real `server/index.js` in production mode (DEV unset/false) against an
// isolated temp cwd, so `.auth/` (server/auth.js) and `app-builds/` (server/index.js)
// don't touch the real project's data or collide with other test files' servers.
// Production mode is used deliberately, not DEV mode: none of these tests exercise the
// dev-only "accept unknown uuid" bypass in src/Server.elm's ClientStateRequest handler,
// and PROD_SERVER_PORT can be overridden to an unprivileged test port just as well as
// DEV_SERVER_PORT could.
async function startTestServer({ port, seedUsers = [] }) {
    if (!fs.existsSync(ELM_SERVER_JS)) {
        throw new Error('elm-server.js not found — run: npm run build:server');
    }

    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'beckett-test-'));
    const authDir = path.join(tempDir, '.auth');
    fs.mkdirSync(authDir, { recursive: true });
    for (const user of seedUsers) seedUser(authDir, user);
    fs.mkdirSync(path.join(tempDir, 'app-builds'), { recursive: true });

    const child = spawn(process.execPath, [SERVER_SCRIPT], {
        cwd: tempDir,
        // Spread parent env so PATH/HOME/etc are inherited; override mode/port.
        // dotenv (loaded inside server/index.js) doesn't override existing env vars,
        // so these values win over whatever is in the .env file.
        env: { ...process.env, DEV: 'false', PROD_SERVER_PORT: String(port) },
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
            if (stdoutBuf.includes(`WebSocket server listening on port ${port}`)) {
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

    async function stop() {
        if (child.exitCode === null) {
            await new Promise((resolve) => {
                // Escalate to SIGKILL after 5s; resolve regardless so teardown always completes
                const killTimer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 5000);
                child.once('exit', () => { clearTimeout(killTimer); resolve(); });
                child.kill('SIGTERM');
            });
        }
        fs.rmSync(tempDir, { recursive: true, force: true });
    }

    return { tempDir, stop };
}

module.exports = { startTestServer, PROJECT_ROOT, ELM_SERVER_JS };
