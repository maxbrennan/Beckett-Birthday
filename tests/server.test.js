const { test } = require('node:test');
const assert = require('node:assert/strict');
const { isAdminAuth } = require('../server/auth.js');

test('admin with level 2 is allowed', () => {
    assert.equal(isAdminAuth({ success: true, level: 2 }), true);
});

test('level 1 user is rejected even on success (distUndeploy bug fixed in PR#5)', () => {
    assert.equal(isAdminAuth({ success: true, level: 1 }), false);
});

test('level 0 user is rejected', () => {
    assert.equal(isAdminAuth({ success: true, level: 0 }), false);
});

test('failed auth with level 2 is rejected (distList bug fixed in PR#5)', () => {
    assert.equal(isAdminAuth({ success: false, level: 2 }), false);
});

test('empty variant is rejected', () => {
    assert.equal(isAdminAuth({}), false);
});
