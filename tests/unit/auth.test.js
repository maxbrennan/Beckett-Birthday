'use strict';

// The client half of server/auth.js's two-level challenge–response flow, driven
// through the same `opts` seams the integration AdminClient uses (clientDir /
// credentials / session), so no test touches the real ~/.birthday-auth identity
// or the repo's .auth/. Server-side success paths (which append to .auth/) are
// covered end to end by tests/integration/auth-*.test.js instead.
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const auth = require('../../server/auth.js');

function tempClientDir() {
    return fs.mkdtempSync(path.join(os.tmpdir(), 'birthday-auth-test-'));
}

const challenge = crypto.randomBytes(32);

describe('generateAuthChallenge', () => {
    test('issues a fresh 32-byte admin-level challenge', () => {
        const issued = auth.generateAuthChallenge();
        expect(issued.challenge.length).toBe(32);
        expect(issued.level).toBe(2);
    });
});

describe('handleAuthChallenge', () => {
    test('first auth (no stored keys) answers with password credentials and a freshly generated public key', async () => {
        const clientDir = tempClientDir();
        const session = { keyAuthFailed: false, uuid: null };

        const response = await auth.handleAuthChallenge(
            { challenge, level: 2 },
            { clientDir, session, credentials: async () => ({ username: 'u', password: 'p' }) }
        );

        expect(response.password.username).toBe('u');
        expect(response.password.password).toBe('p');
        expect(response.password.publicKey.toString('utf8')).toContain('BEGIN PUBLIC KEY');
        // The keypair is persisted so the next login can skip the password.
        expect(auth._internals.hasKeys(2, clientDir)).toBe(true);
    });

    test('with stored keys, signs the challenge so the stored public key verifies it', async () => {
        const clientDir = tempClientDir();
        auth._internals.loadOrGenerateKeys(2, clientDir);
        const session = { keyAuthFailed: false, uuid: 'uuid-123' };

        const response = await auth.handleAuthChallenge({ challenge, level: 2 }, { clientDir, session });

        expect(response.key.uuid).toBe('uuid-123');
        const publicKeyPem = fs.readFileSync(auth._internals.publicKeyPath(2, clientDir), 'utf8');
        expect(crypto.verify(null, challenge, publicKeyPem, response.key.challengeResponse)).toBe(true);
    });

    test('forcePassword skips a usable stored key', async () => {
        const clientDir = tempClientDir();
        auth._internals.loadOrGenerateKeys(2, clientDir);
        const session = { keyAuthFailed: false, uuid: null };

        const response = await auth.handleAuthChallenge(
            { challenge, level: 2 },
            { clientDir, session, forcePassword: true, credentials: async () => ({ username: 'u', password: 'p' }) }
        );

        expect(response.password).toBeDefined();
        expect(response.key).toBeUndefined();
    });

    test('after a key failure, retries with password and a regenerated keypair', async () => {
        const clientDir = tempClientDir();
        auth._internals.loadOrGenerateKeys(2, clientDir);
        const before = fs.readFileSync(auth._internals.publicKeyPath(2, clientDir), 'utf8');
        const session = { keyAuthFailed: true, uuid: null };

        const response = await auth.handleAuthChallenge(
            { challenge, level: 2 },
            { clientDir, session, credentials: async () => ({ username: 'u', password: 'p' }) }
        );
        const after = fs.readFileSync(auth._internals.publicKeyPath(2, clientDir), 'utf8');

        expect(response.password).toBeDefined();
        expect(after).not.toBe(before); // stale key overwritten, fresh one registered
    });
});

describe('handleAuthResponse (server side, failure paths)', () => {
    test('an unknown username fails password auth closed', () => {
        const result = auth.handleAuthResponse(
            {
                method: 'password',
                password: { username: 'definitely-not-a-user', password: 'x', publicKey: Buffer.from('') },
            },
            challenge
        );
        expect(result.password).toEqual({ success: false, level: 0, uuid: '' });
    });

    test('an unknown uuid fails key auth closed', () => {
        const result = auth.handleAuthResponse(
            { method: 'key', key: { uuid: 'no-such-uuid', challengeResponse: Buffer.from('') } },
            challenge
        );
        expect(result.key).toEqual({ success: false, level: 0 });
    });

    test('an unrecognized method fails closed', () => {
        const result = auth.handleAuthResponse({ method: 'carrier-pigeon' }, challenge);
        expect(result.key).toEqual({ success: false, level: 0 });
    });
});

describe('handleAuthResult', () => {
    test('password success stores the uuid in the session and persists it for the next run', () => {
        const clientDir = tempClientDir();
        const session = { keyAuthFailed: true, uuid: null };

        auth.handleAuthResult(
            { result: 'password', password: { success: true, level: 2, uuid: 'uuid-9' } },
            { clientDir, session }
        );

        expect(session.uuid).toBe('uuid-9');
        expect(session.keyAuthFailed).toBe(false);
        expect(auth._internals.loadStoredUuid(clientDir)).toBe('uuid-9');
    });

    test('password failure leaves the session untouched', () => {
        const session = { keyAuthFailed: false, uuid: null };
        auth.handleAuthResult(
            { result: 'password', password: { success: false, level: 0, uuid: '' } },
            { clientDir: tempClientDir(), session }
        );
        expect(session).toEqual({ keyAuthFailed: false, uuid: null });
    });

    test('key failure flags the session so the caller retries with password', () => {
        const session = { keyAuthFailed: false, uuid: null };
        auth.handleAuthResult({ result: 'key', key: { success: false, level: 0 } }, { clientDir: tempClientDir(), session });
        expect(session.keyAuthFailed).toBe(true);
    });

    test('key success changes no session state', () => {
        const session = { keyAuthFailed: false, uuid: 'uuid-1' };
        auth.handleAuthResult({ result: 'key', key: { success: true, level: 2 } }, { clientDir: tempClientDir(), session });
        expect(session).toEqual({ keyAuthFailed: false, uuid: 'uuid-1' });
    });

    test('an unknown result variant is a no-op', () => {
        const session = { keyAuthFailed: false, uuid: null };
        auth.handleAuthResult({ result: 'other' }, { clientDir: tempClientDir(), session });
        expect(session).toEqual({ keyAuthFailed: false, uuid: null });
    });
});

describe('loadStoredUuid', () => {
    test('null when nothing has been persisted yet', () => {
        expect(auth._internals.loadStoredUuid(tempClientDir())).toBeNull();
    });

    test('null when the stored file is malformed', () => {
        const clientDir = tempClientDir();
        fs.writeFileSync(path.join(clientDir, 'uuid.env'), 'not the expected format');
        expect(auth._internals.loadStoredUuid(clientDir)).toBeNull();
    });
});
