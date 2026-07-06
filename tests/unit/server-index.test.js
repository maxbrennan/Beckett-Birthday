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
    const registryText = [
        JSON.stringify({ uuid: 'uuid-a', filename: 'a.dmg' }),
        JSON.stringify({ uuid: 'uuid-b', filename: 'b.exe' }),
        'not json',
    ].join('\n');

    test('finds the matching entry by uuid', () => {
        expect(findRegistryEntry(registryText, 'uuid-b')).toEqual({ uuid: 'uuid-b', filename: 'b.exe' });
    });

    test('returns null when no entry matches', () => {
        expect(findRegistryEntry(registryText, 'uuid-z')).toBeNull();
    });

    test('skips malformed JSONL lines without throwing', () => {
        expect(() => findRegistryEntry(registryText, 'uuid-a')).not.toThrow();
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
    test('mints a token and rewrites the ack when mintUploadToken marker is present', () => {
        const mintToken = () => 'minted-token';
        const result = buildSendToClientPayload({ ack: { mintUploadToken: true } }, mintToken);
        expect(result).toEqual({ serverPayload: { ack: { uploadToken: 'minted-token' } }, token: 'minted-token' });
    });

    test('passes other payloads through unchanged', () => {
        const mintToken = jest.fn();
        const payload = { authChallenge: { challenge: 'xyz', level: 2 } };
        const result = buildSendToClientPayload(payload, mintToken);
        expect(result).toEqual({ serverPayload: payload, token: null });
        expect(mintToken).not.toHaveBeenCalled();
    });
});
