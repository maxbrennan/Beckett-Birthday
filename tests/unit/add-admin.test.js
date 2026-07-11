'use strict';

// scripts/add-admin.js's main() runs unconditionally only when invoked as
// `node scripts/add-admin.js` (require.main === module); requiring it from Jest just
// exposes the two pure helpers below.
const { validateCredentials, buildAdminRow } = require('../../scripts/add-admin.js');

describe('validateCredentials', () => {
    test('true when both username and password are present', () => {
        expect(validateCredentials({ username: 'admin', password: 'hunter2' })).toBe(true);
    });

    test('false when username is missing', () => {
        expect(validateCredentials({ username: '', password: 'hunter2' })).toBe(false);
    });

    test('false when password is missing', () => {
        expect(validateCredentials({ username: 'admin', password: '' })).toBe(false);
    });
});

describe('buildAdminRow', () => {
    test('builds a level-2 admin row using the injected hash function', () => {
        const hashFn = jest.fn((password, salt) => `${password}:${salt}`);
        const row = buildAdminRow('admin', 'hunter2', 'salt123', hashFn);
        expect(row).toEqual({ username: 'admin', salt: 'salt123', hash: 'hunter2:salt123', level: 2 });
        expect(hashFn).toHaveBeenCalledWith('hunter2', 'salt123');
    });
});
