const { isAdminAuth } = require('../server/auth.js');

test('admin with level 2 is allowed', () => {
    expect(isAdminAuth({ success: true, level: 2 })).toBe(true);
});

test('level 1 user is rejected even on success (distUndeploy bug fixed in PR#5)', () => {
    expect(isAdminAuth({ success: true, level: 1 })).toBe(false);
});

test('level 0 user is rejected', () => {
    expect(isAdminAuth({ success: true, level: 0 })).toBe(false);
});

test('failed auth with level 2 is rejected (distList bug fixed in PR#5)', () => {
    expect(isAdminAuth({ success: false, level: 2 })).toBe(false);
});

test('empty variant is rejected', () => {
    expect(isAdminAuth({})).toBe(false);
});
