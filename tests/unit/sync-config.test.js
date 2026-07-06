'use strict';

const { updatePackageJson, updateIndexHtml } = require('../../scripts/sync-config.js');

// Guards issue #35: config/app-config.json's "appName" is the single source of truth
// for the recipient name, propagated at build time into package.json's productName
// (Electron's app.getName() / electron-builder's DMG/EXE naming) and index.html's
// <title> (the window title, since electron.js sets no BrowserWindow title override).
describe('updatePackageJson', () => {
    const pkg = [
        '{',
        '  "name": "birthday-present",',
        '  "productName": "Ryan Birthday",',
        '  "version": "3.0.0"',
        '}',
        '',
    ].join('\n');

    test('replaces productName, leaving everything else untouched', () => {
        const updated = updatePackageJson(pkg, 'Beckett Birthday');
        expect(updated).toContain('"productName": "Beckett Birthday"');
        expect(updated).toContain('"name": "birthday-present"');
        expect(updated).toContain('"version": "3.0.0"');
    });

    test('is idempotent: re-running with the same name is a no-op', () => {
        const once = updatePackageJson(pkg, 'Ryan Birthday');
        const twice = updatePackageJson(once, 'Ryan Birthday');
        expect(once).toBe(pkg);
        expect(twice).toBe(once);
    });

    test('throws if no productName field is found', () => {
        expect(() => updatePackageJson('{ "name": "x" }', 'Ryan Birthday')).toThrow();
    });
});

describe('updateIndexHtml', () => {
    const html = [
        '<!DOCTYPE html>',
        '<html lang="en">',
        '<head>',
        '  <meta charset="UTF-8">',
        '  <title>Ryan Birthday</title>',
        '</head>',
        '<body></body>',
        '</html>',
        '',
    ].join('\n');

    test('replaces the <title> tag, leaving everything else untouched', () => {
        const updated = updateIndexHtml(html, 'Beckett Birthday');
        expect(updated).toContain('<title>Beckett Birthday</title>');
        expect(updated).toContain('<meta charset="UTF-8">');
    });

    test('is idempotent: re-running with the same name is a no-op', () => {
        const once = updateIndexHtml(html, 'Ryan Birthday');
        const twice = updateIndexHtml(once, 'Ryan Birthday');
        expect(once).toBe(html);
        expect(twice).toBe(once);
    });

    test('throws if no <title> tag is found', () => {
        expect(() => updateIndexHtml('<html></html>', 'Ryan Birthday')).toThrow();
    });
});
