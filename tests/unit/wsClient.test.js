'use strict';

const { EventEmitter } = require('events');
const {
    computeServerUrl,
    createMessageQueue,
    wireSocket,
    classifyAuthResult,
    formatBuildListLine,
} = require('../../scripts/lib/wsClient.js');

describe('computeServerUrl', () => {
    test('port 443 omits the :port suffix', () => {
        expect(computeServerUrl({ PROD_SERVER_HOST: 'example.com', PROD_SERVER_PORT: '443' }))
            .toBe('wss://example.com');
    });

    test('non-443 port is included', () => {
        expect(computeServerUrl({ PROD_SERVER_HOST: 'example.com', PROD_SERVER_PORT: '8443' }))
            .toBe('wss://example.com:8443');
    });

    test('defaults to port 443 when PROD_SERVER_PORT is unset', () => {
        expect(computeServerUrl({ PROD_SERVER_HOST: 'example.com' })).toBe('wss://example.com');
    });
});

describe('createMessageQueue', () => {
    test('resolves immediately when a message already arrived before nextMessage was called', async () => {
        const { nextMessage, pushMessage } = createMessageQueue();
        pushMessage({ payload: 'ack' });
        await expect(nextMessage()).resolves.toEqual({ payload: 'ack' });
    });

    test('resolves a pending nextMessage() when a message arrives later', async () => {
        const { nextMessage, pushMessage } = createMessageQueue();
        const pending = nextMessage();
        pushMessage({ payload: 'authChallenge' });
        await expect(pending).resolves.toEqual({ payload: 'authChallenge' });
    });

    test('delivers messages in FIFO order', async () => {
        const { nextMessage, pushMessage } = createMessageQueue();
        pushMessage({ payload: 'first' });
        pushMessage({ payload: 'second' });
        await expect(nextMessage()).resolves.toEqual({ payload: 'first' });
        await expect(nextMessage()).resolves.toEqual({ payload: 'second' });
    });
});

describe('wireSocket', () => {
    test('decodes incoming messages via the codec and pushes them to the queue', () => {
        const socket = new EventEmitter();
        const pushMessage = jest.fn();
        const codec = { decodeServer: (data) => ({ payload: 'ack', raw: data }) };
        wireSocket(socket, { codec, pushMessage, tag: 'test' });

        socket.emit('message', 'bytes');
        expect(pushMessage).toHaveBeenCalledWith({ payload: 'ack', raw: 'bytes' });
    });

    test('swallows decode errors and does not push a message', () => {
        const socket = new EventEmitter();
        const pushMessage = jest.fn();
        const codec = { decodeServer: () => { throw new Error('bad'); } };
        wireSocket(socket, { codec, pushMessage, tag: 'test' });

        expect(() => socket.emit('message', 'bytes')).not.toThrow();
        expect(pushMessage).not.toHaveBeenCalled();
    });

    test('pushes a synthetic _closed sentinel when the socket closes', () => {
        const socket = new EventEmitter();
        const pushMessage = jest.fn();
        wireSocket(socket, { codec: {}, pushMessage, tag: 'test' });

        socket.emit('close');
        expect(pushMessage).toHaveBeenCalledWith({ payload: '_closed' });
    });
});

describe('classifyAuthResult', () => {
    test('successful password auth', () => {
        expect(classifyAuthResult({ password: { success: true, level: 2 } }))
            .toEqual({ success: true, isKeyFailure: false });
    });

    test('failed password auth', () => {
        expect(classifyAuthResult({ password: { success: false } }))
            .toEqual({ success: false, isKeyFailure: false });
    });

    test('key auth failure triggers a password retry, not an immediate failure', () => {
        expect(classifyAuthResult({ key: { success: false } }))
            .toEqual({ success: false, isKeyFailure: true });
    });

    test('successful key auth', () => {
        expect(classifyAuthResult({ key: { success: true, level: 2 } }))
            .toEqual({ success: true, isKeyFailure: false });
    });
});

describe('formatBuildListLine', () => {
    test('formats uuid, filename, and platform', () => {
        expect(formatBuildListLine({ uuid: 'uuid-a', filename: 'a.dmg', platform: 'mac' }))
            .toBe('  uuid-a  a.dmg  (mac)');
    });
});
