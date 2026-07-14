'use strict';

// bridge.js requires('ws') and './server/codec.js' at module scope but only runs the
// Elm.init/port-wiring block when `document` exists (see the require.main-style guard
// in client/bridge.js) — under plain Jest/Node there's no DOM, so requiring it here
// only exposes the pure helpers below.
const { computeWsUrl, resolveReadFilePath, decodeIncomingWsMessage, handleReadFileResult, handleReadDirResult, handleWriteCacheFileResult } = require('../../client/bridge.js');

describe('computeWsUrl', () => {
    test('dev mode always uses localhost regardless of PROD_SERVER_HOST', () => {
        expect(computeWsUrl({ DEV: 'true', DEV_SERVER_PORT: '8443', PROD_SERVER_HOST: 'example.com' }))
            .toBe('wss://localhost:8443');
    });

    test('production mode uses PROD_SERVER_HOST/PROD_SERVER_PORT', () => {
        expect(computeWsUrl({ DEV: 'false', PROD_SERVER_HOST: 'example.com', PROD_SERVER_PORT: '8443' }))
            .toBe('wss://example.com:8443');
    });

    test('port 443 omits the :port suffix', () => {
        expect(computeWsUrl({ DEV: 'false', PROD_SERVER_HOST: 'example.com', PROD_SERVER_PORT: '443' }))
            .toBe('wss://example.com');
    });
});

describe('resolveReadFilePath', () => {
    test('returns absolute paths unchanged', () => {
        expect(resolveReadFilePath('/tmp/foo.json', '/base')).toBe('/tmp/foo.json');
    });

    test('joins relative paths against baseDir', () => {
        expect(resolveReadFilePath('config/foo.json', '/base')).toBe('/base/config/foo.json');
    });
});

describe('decodeIncomingWsMessage', () => {
    test('decodes via the codec and returns a JSON string', () => {
        const fakeCodec = { decodeServer: (data) => ({ payload: 'ack', ack: { uploadToken: data.toString() } }) };
        const result = decodeIncomingWsMessage('raw-bytes', fakeCodec);
        expect(JSON.parse(result)).toEqual({ payload: 'ack', ack: { uploadToken: 'raw-bytes' } });
    });

    test('propagates a decode error to the caller', () => {
        const fakeCodec = { decodeServer: () => { throw new Error('bad protobuf'); } };
        expect(() => decodeIncomingWsMessage('raw-bytes', fakeCodec)).toThrow('bad protobuf');
    });
});

describe('handleReadFileResult', () => {
    test('maps a read error to an error result', () => {
        expect(handleReadFileResult(new Error('ENOENT'), null, 'foo.json'))
            .toEqual({ path: 'foo.json', contents: null, error: 'ENOENT' });
    });

    test('maps successful data to a contents result', () => {
        expect(handleReadFileResult(null, 'hello', 'foo.json'))
            .toEqual({ path: 'foo.json', contents: 'hello', error: null });
    });
});

describe('handleReadDirResult', () => {
    test('maps a read error to an empty-files error result', () => {
        expect(handleReadDirResult(new Error('ENOENT'), null, 'assets/songs'))
            .toEqual({ path: 'assets/songs', files: [], error: 'ENOENT' });
    });

    test('maps a successful listing to a files result', () => {
        expect(handleReadDirResult(null, ['0.mp3', '1.mp4'], 'assets/songs'))
            .toEqual({ path: 'assets/songs', files: ['0.mp3', '1.mp4'], error: null });
    });

    test('a null file list from fs.readdir defaults to empty', () => {
        expect(handleReadDirResult(null, null, 'assets/songs'))
            .toEqual({ path: 'assets/songs', files: [], error: null });
    });
});

describe('handleWriteCacheFileResult', () => {
    test('maps a write error to an error result', () => {
        expect(handleWriteCacheFileResult(new Error('EACCES'), 'iq-offer-grant.json'))
            .toEqual({ path: 'iq-offer-grant.json', ok: false, error: 'EACCES' });
    });

    test('maps a successful write to an ok result', () => {
        expect(handleWriteCacheFileResult(null, 'iq-offer-grant.json'))
            .toEqual({ path: 'iq-offer-grant.json', ok: true, error: null });
    });
});
