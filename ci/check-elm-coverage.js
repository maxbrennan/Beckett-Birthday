'use strict';

// Enforces a coverage floor from the Elm unit test run's existing capture data — does
// NOT re-run elm-test. `elm-coverage generate` recomputes a report from the
// `.coverage/info.json` (static declaration list) + `.coverage/instrumented/data-*.json`
// (runtime hit counts) left behind by `npm run test:elm`'s full instrumented run, so this
// only works after that data exists (or has been downloaded as a CI artifact from the
// elm-unit job).
//
// elm-coverage deliberately doesn't condense its report to a single percentage (see its
// README), so this script computes one itself: declarations with a runtime hit count > 0,
// divided by all declarations found across src/.
//
// The threshold is an intentional interim floor (see issue #26's follow-up), not the
// eventual 95% target — it ratchets up as tests/refactors close the gap.

const { execFileSync } = require('child_process');

const THRESHOLD = Number(process.argv[2]);

if (Number.isNaN(THRESHOLD)) {
    console.error('Usage: node ci/check-elm-coverage.js <threshold-percent>');
    process.exit(1);
}

let output;
try {
    output = execFileSync('npx', ['elm-coverage', 'generate', '--report', 'json'], {
        encoding: 'utf8',
    });
} catch (err) {
    console.error('Failed to generate the Elm coverage report from captured data.');
    console.error('Run `npm run test:elm` first to produce .coverage/.');
    console.error(err.message);
    process.exit(1);
}

const { coverageData } = JSON.parse(output.trim().split('\n').pop());

let total = 0;
let covered = 0;
for (const entries of Object.values(coverageData)) {
    for (const entry of entries) {
        total += 1;
        if (entry.count > 0) covered += 1;
    }
}

const pct = (100 * covered) / total;
const status = pct >= THRESHOLD ? 'OK' : 'FAIL';
console.log(`elm coverage ${pct.toFixed(2)}% (${covered}/${total} declarations, threshold ${THRESHOLD}%) [${status}]`);

if (pct < THRESHOLD) {
    console.error(`\nElm coverage is below the ${THRESHOLD}% floor.`);
    process.exit(1);
}

console.log(`\nElm coverage meets the ${THRESHOLD}% floor.`);
