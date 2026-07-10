'use strict';

// Isolates just the productName/title values so the rest of each file's formatting
// (package.json's "build"."//" comment key, key order, index.html's structure) is
// preserved untouched.
const PRODUCT_NAME_RE = /"productName":\s*"[^"]*"/;
const TITLE_RE = /<title>[^<]*<\/title>/;

function updatePackageJson(contents, appName) {
    if (!PRODUCT_NAME_RE.test(contents)) {
        throw new Error('package.json: could not find a "productName" field to update');
    }
    return contents.replace(PRODUCT_NAME_RE, `"productName": "${appName}"`);
}

function updateIndexHtml(contents, appName) {
    if (!TITLE_RE.test(contents)) {
        throw new Error('index.html: could not find a <title> tag to update');
    }
    return contents.replace(TITLE_RE, `<title>${appName}</title>`);
}

module.exports = { updatePackageJson, updateIndexHtml };

// Everything below is the `node scripts/sync-config.js` CLI entry point. Guarded so
// tests can require() this file for the pure update functions without touching disk.
if (require.main === module) {
    const fs = require('fs');
    const path = require('path');

    const ROOT = path.join(__dirname, '..');
    const CONFIG_PATH = path.join(ROOT, 'config', 'app-config.json');
    const PACKAGE_JSON_PATH = path.join(ROOT, 'package.json');
    const INDEX_HTML_PATH = path.join(ROOT, 'index.html');

    // config/app-config.json is git-ignored (it also holds quiz answers/win text --
    // real spoilers, see config/app-config.example.json). A fresh clone won't have
    // it yet, so leave package.json/index.html's already-committed values standing
    // rather than erroring the build.
    if (!fs.existsSync(CONFIG_PATH)) {
        console.log(`[sync-config] ${CONFIG_PATH} not found, skipping naming sync`);
        process.exit(0);
    }

    const { appName } = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    if (typeof appName !== 'string' || appName === '') {
        console.error(`[sync-config] ${CONFIG_PATH} must contain a non-empty "appName" string`);
        process.exit(1);
    }

    for (const [label, filePath, update] of [
        ['package.json', PACKAGE_JSON_PATH, updatePackageJson],
        ['index.html', INDEX_HTML_PATH, updateIndexHtml],
    ]) {
        const before = fs.readFileSync(filePath, 'utf8');
        const after = update(before, appName);
        if (after !== before) {
            fs.writeFileSync(filePath, after);
            console.log(`[sync-config] updated ${label} to "${appName}"`);
        }
    }
}
