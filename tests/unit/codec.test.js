'use strict';

// server/codec.js is the single protobuf boundary for both directions of the
// wire (bridge.js and server/index.js call nothing else) — these round trips
// pin the conventions everything downstream assumes: `oneofs: true` surfaces
// the active variant name as `payload`, `defaults: true` materializes omitted
// fields (Sync.elm's decoders lean on this — see SyncTest's quizAnswerResult
// defaults test), and `bytes: String` yields base64 strings, not Buffers.
const codec = require('../../server/codec.js');

describe('client message round trips (encodeClient -> decodeClient)', () => {
    test('stateUpdate carries its json and names itself via the oneof tag', () => {
        const decoded = codec.decodeClient(codec.encodeClient({ stateUpdate: { json: '{"screen":{"tag":"BeginScreen"}}' } }));
        expect(decoded.payload).toBe('stateUpdate');
        expect(decoded.stateUpdate.json).toBe('{"screen":{"tag":"BeginScreen"}}');
    });

    test('quizAnswerSubmitted carries idx and answer', () => {
        const decoded = codec.decodeClient(codec.encodeClient({ quizAnswerSubmitted: { idx: 1, answer: 'answer one' } }));
        expect(decoded.payload).toBe('quizAnswerSubmitted');
        expect(decoded.quizAnswerSubmitted).toEqual({ idx: 1, answer: 'answer one' });
    });

    test('quizAdvanced materializes an omitted idx as the proto default 0', () => {
        const decoded = codec.decodeClient(codec.encodeClient({ quizAdvanced: {} }));
        expect(decoded.quizAdvanced.idx).toBe(0);
    });

    test('stateRequest carries the uuid', () => {
        const decoded = codec.decodeClient(codec.encodeClient({ stateRequest: { uuid: 'uuid-1' } }));
        expect(decoded.stateRequest.uuid).toBe('uuid-1');
    });
});

describe('server message round trips (encodeServer -> decodeServer)', () => {
    test('winText carries its text', () => {
        const decoded = codec.decodeServer(codec.encodeServer({ winText: { text: 'you win' } }));
        expect(decoded.payload).toBe('winText');
        expect(decoded.winText.text).toBe('you win');
    });

    test('quizAnswerResult materializes omitted correct/revealAnswer as false/""', () => {
        const decoded = codec.decodeServer(codec.encodeServer({ quizAnswerResult: { idx: 2 } }));
        expect(decoded.quizAnswerResult).toEqual({ idx: 2, correct: false, revealAnswer: '' });
    });

    test('authChallenge bytes surface as a base64 string, not a Buffer', () => {
        const challenge = Buffer.from('0123456789abcdef');
        const decoded = codec.decodeServer(codec.encodeServer({ authChallenge: { challenge, level: 2 } }));
        expect(decoded.authChallenge.challenge).toBe(challenge.toString('base64'));
        expect(decoded.authChallenge.level).toBe(2);
    });
});
