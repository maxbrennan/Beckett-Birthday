'use strict';

// Enforces a coverage floor from the JS unit test run's existing report — does NOT
// re-run jest. Reads coverage/js/coverage-summary.json (written by the "json-summary"
// jest coverage reporter during `npm run test:unit:js`), so this only works after that
// report has been generated (or downloaded as a CI artifact from the js-unit job).
//
// The threshold is an intentional interim floor (see issue #26's follow-up), not the
// eventual 95% target — it ratchets up as tests/refactors close the gap.

const fs = require('fs');
const path = require('path');

const THRESHOLD = Number(process.argv[2]);
const SUMMARY_PATH = path.join(__dirname, '..', 'coverage', 'js', 'coverage-summary.json');

if (Number.isNaN(THRESHOLD)) {
    console.error('Usage: node ci/check-js-coverage.js <threshold-percent>');
    process.exit(1);
}

if (!fs.existsSync(SUMMARY_PATH)) {
    console.error(`No coverage summary found at ${SUMMARY_PATH}. Run \`npm run test:unit:js\` first.`);
    process.exit(1);
}

const { total } = JSON.parse(fs.readFileSync(SUMMARY_PATH, 'utf8'));
const metrics = ['statements', 'branches', 'functions', 'lines'];

let failed = false;
for (const metric of metrics) {
    const pct = total[metric].pct;
    const status = pct >= THRESHOLD ? 'OK' : 'FAIL';
    if (pct < THRESHOLD) failed = true;
    console.log(`${metric.padEnd(10)} ${pct.toFixed(2)}% (threshold ${THRESHOLD}%) [${status}]`);
}

if (failed) {
    console.error(`\nJS coverage is below the ${THRESHOLD}% floor.`);
    process.exit(1);
}

console.log(`\nJS coverage meets the ${THRESHOLD}% floor.`);
