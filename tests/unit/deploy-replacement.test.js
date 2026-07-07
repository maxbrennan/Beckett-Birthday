'use strict';

const crypto = require('crypto');
const { resolveReplacement } = require('../../scripts/deploy-replacement.js');

// The CLI (scripts/deploy-replacement.js) gates on the distList result BEFORE
// generating a uuid or running electron-builder — the server protocol accepts any
// oldUuid regardless of existence (see tests/integration/deploy-replacement.test.js),
// so refusing a nonexistent uuid is client-side logic. resolveReplacement is that
// decision, and it's pure — no server needed to exercise it.
describe('resolveReplacement (CLI pre-build gate)', () => {
    const entries = [
        { uuid: 'uuid-a', filename: 'a.dmg', platform: 'mac' },
        { uuid: 'uuid-b', filename: 'b.exe', platform: 'win' },
    ];

    test('no uuid given -> list (show deployed builds, do not build)', () => {
        expect(resolveReplacement(entries, undefined).action).toBe('list');
        expect(resolveReplacement(entries, '').action).toBe('list');
    });

    test('nonexistent uuid -> abort (refuse, do not build)', () => {
        expect(resolveReplacement(entries, crypto.randomUUID()).action).toBe('abort');
        // abort even when there is nothing deployed at all
        expect(resolveReplacement([], 'uuid-a').action).toBe('abort');
    });

    test('existing uuid -> proceed', () => {
        expect(resolveReplacement(entries, 'uuid-a').action).toBe('proceed');
    });
});
