'use strict';

// scripts/edit-state.js's main() only runs when invoked as `node scripts/edit-state.js`
// (require.main === module); requiring it from Jest just exposes validateEditedJson.
const { validateEditedJson } = require('../../scripts/edit-state.js');

describe('validateEditedJson', () => {
    test('ok for valid JSON', () => {
        expect(validateEditedJson('{"screen": "BeginScreen"}')).toEqual({ ok: true });
    });

    test('not ok for invalid JSON, with an error message', () => {
        const result = validateEditedJson('{not valid json');
        expect(result.ok).toBe(false);
        expect(typeof result.error).toBe('string');
    });
});
