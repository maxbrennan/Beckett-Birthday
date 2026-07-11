'use strict';

const fs = require('fs');
const path = require('path');

function registryFilePath(tempDir) {
    return path.join(tempDir, 'app-builds', 'builds.json');
}

// A concurrent writeFile port write (server/index.js) truncates the file before writing
// its new contents, so a read that lands mid-write can see a torn/empty/partial document.
// Treat a parse failure the same as a missing file -- callers polling via waitUntil then
// just see [] and retry, rather than the read throwing and failing the test outright.
function readRegistry(tempDir) {
    const file = registryFilePath(tempDir);
    if (!fs.existsSync(file)) return [];
    try {
        const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
        return doc.builds || [];
    } catch (_) {
        return [];
    }
}

function writeRegistry(tempDir, entries) {
    fs.writeFileSync(registryFilePath(tempDir), JSON.stringify({ builds: entries }, null, 2) + '\n');
}

module.exports = { registryFilePath, readRegistry, writeRegistry };
