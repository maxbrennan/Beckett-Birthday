'use strict';

// server/index.js requires ../elm-server.js and ./auth.js at module scope, but all I/O
// (TLS cert reads, fs.watch, server.listen, port wiring) is gated behind
// `require.main === module` — requiring it from Jest only exposes the pure/mockable
// functions below without binding a real port. Run `npm run build:server` first if
// elm-server.js hasn't been built yet.
const {
    resolveCertPaths,
    parseUploadRequest,
    isValidUuid,
    findRegistryEntry,
    resolveDownloadDecision,
    buildSendToClientPayload,
    writeFileAtomic,
} = require('../../server/index.js');

describe('resolveCertPaths', () => {
    test('defaults to certs/cert.pem and certs/key.pem under rootDir', () => {
        expect(resolveCertPaths({}, '/app')).toEqual({
            certFile: '/app/certs/cert.pem',
            keyFile: '/app/certs/key.pem',
        });
    });

    test('honors SSL_CERT_FILE/SSL_KEY_FILE overrides', () => {
        expect(resolveCertPaths({ SSL_CERT_FILE: 'custom/cert.pem', SSL_KEY_FILE: 'custom/key.pem' }, '/app')).toEqual({
            certFile: '/app/custom/cert.pem',
            keyFile: '/app/custom/key.pem',
        });
    });
});

describe('parseUploadRequest', () => {
    test('extracts a bearer token and validates the filename', () => {
        const req = { headers: { authorization: 'Bearer abc123', 'x-filename': 'build.dmg' } };
        expect(parseUploadRequest(req)).toEqual({ token: 'abc123', filename: 'build.dmg', filenameValid: true });
    });

    test('missing Authorization header yields an empty token', () => {
        const req = { headers: { 'x-filename': 'build.dmg' } };
        expect(parseUploadRequest(req).token).toBe('');
    });

    test('rejects a filename containing ".." or "/"', () => {
        expect(parseUploadRequest({ headers: { 'x-filename': '../evil.dmg' } }).filenameValid).toBe(false);
        expect(parseUploadRequest({ headers: { 'x-filename': 'sub/evil.dmg' } }).filenameValid).toBe(false);
    });

    test('rejects an empty filename', () => {
        expect(parseUploadRequest({ headers: {} }).filenameValid).toBe(false);
    });
});

describe('isValidUuid', () => {
    test('accepts a 36-char hex/dash string', () => {
        expect(isValidUuid('123e4567-e89b-12d3-a456-426614174000')).toBe(true);
    });

    test('rejects anything else', () => {
        expect(isValidUuid('not-a-uuid')).toBe(false);
        expect(isValidUuid('../../etc/passwd')).toBe(false);
        expect(isValidUuid('')).toBe(false);
    });
});

describe('findRegistryEntry', () => {
    const registryText = JSON.stringify({
        builds: [
            { uuid: 'uuid-a', filename: 'a.dmg' },
            { uuid: 'uuid-b', filename: 'b.exe' },
        ],
    });

    test('finds the matching entry by uuid', () => {
        expect(findRegistryEntry(registryText, 'uuid-b')).toEqual({ uuid: 'uuid-b', filename: 'b.exe' });
    });

    test('returns null when no entry matches', () => {
        expect(findRegistryEntry(registryText, 'uuid-z')).toBeNull();
    });

    test('returns null on malformed JSON without throwing', () => {
        expect(() => findRegistryEntry('not json', 'uuid-a')).not.toThrow();
        expect(findRegistryEntry('not json', 'uuid-a')).toBeNull();
    });
});

describe('resolveDownloadDecision', () => {
    test('not-found when entry is null', () => {
        expect(resolveDownloadDecision(null)).toEqual({ type: 'not-found' });
    });

    test('locked when pendingStateEdit is set', () => {
        expect(resolveDownloadDecision({ filename: 'a.dmg', pendingStateEdit: true })).toEqual({ type: 'locked' });
    });

    test('ok with the filename otherwise', () => {
        expect(resolveDownloadDecision({ filename: 'a.dmg' })).toEqual({ type: 'ok', filename: 'a.dmg' });
    });
});

describe('buildSendToClientPayload', () => {
    test('mints a token and rewrites the distRegisterAck when mintUploadToken marker is present', () => {
        const mintToken = () => 'minted-token';
        const result = buildSendToClientPayload({ distRegisterAck: { mintUploadToken: true } }, mintToken);
        expect(result).toEqual({ serverPayload: { distRegisterAck: { uploadToken: 'minted-token' } }, token: 'minted-token' });
    });

    test('passes other payloads through unchanged', () => {
        const mintToken = jest.fn();
        const payload = { authChallenge: { challenge: 'xyz', level: 2 } };
        const result = buildSendToClientPayload(payload, mintToken);
        expect(result).toEqual({ serverPayload: payload, token: null });
        expect(mintToken).not.toHaveBeenCalled();
    });
});

describe('writeFileAtomic', () => {
    const fs = require('fs');
    const os = require('os');
    const path = require('path');
    let dir;

    beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'write-atomic-')); });
    afterEach(() => { fs.rmSync(dir, { recursive: true, force: true }); });

    test('replaces the target file and leaves no temp file behind', (done) => {
        const target = path.join(dir, 'builds.json');
        fs.writeFileSync(target, 'old');
        writeFileAtomic(target, 'new', 'utf8', (err) => {
            expect(err).toBeFalsy();
            expect(fs.readFileSync(target, 'utf8')).toBe('new');
            expect(fs.readdirSync(dir)).toEqual(['builds.json']);
            done();
        });
    });

    test('leaves the original untouched when the temp write fails', (done) => {
        const target = path.join(dir, 'builds.json');
        fs.writeFileSync(target, 'old');
        // A directory squatting on the temp path makes the temp write fail.
        fs.mkdirSync(`${target}.tmp`);
        writeFileAtomic(target, 'new', 'utf8', (err) => {
            expect(err).toBeTruthy();
            expect(fs.readFileSync(target, 'utf8')).toBe('old');
            done();
        });
    });

    function fakeFs(renameErrors) {
        const errs = [...renameErrors];
        return {
            renameCalls: 0,
            writeFile: (_p, _c, _e, cb) => cb(null),
            rename(_from, _to, cb) {
                this.renameCalls += 1;
                const code = errs.shift();
                cb(code ? Object.assign(new Error(code), { code }) : null);
            },
        };
    }

    test('retries a transient Windows EPERM on rename until it succeeds', (done) => {
        const f = fakeFs(['EPERM', 'EBUSY']);
        writeFileAtomic('x/builds.json', 'new', 'utf8', (err) => {
            expect(err).toBeNull();
            expect(f.renameCalls).toBe(3);
            done();
        }, f);
    });

    test('does not retry a non-transient rename error', (done) => {
        const f = fakeFs(['ENOENT']);
        writeFileAtomic('x/builds.json', 'new', 'utf8', (err) => {
            expect(err.code).toBe('ENOENT');
            expect(f.renameCalls).toBe(1);
            done();
        }, f);
    });

    test('gives up after the retry budget and reports the error', (done) => {
        const f = fakeFs(Array(20).fill('EPERM'));
        writeFileAtomic('x/builds.json', 'new', 'utf8', (err) => {
            expect(err.code).toBe('EPERM');
            expect(f.renameCalls).toBe(10);
            done();
        }, f);
    });
});
