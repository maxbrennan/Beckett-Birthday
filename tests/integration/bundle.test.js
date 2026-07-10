'use strict';

const fs = require('fs');
const path = require('path');
const { PROJECT_ROOT } = require('../helpers/certPaths');

// Guards issue #27: the personalized win text must live only on the server (in
// builds.jsonl / config/app-config.json's winScreen field, read at deploy time),
// never compiled into the shipped client bundle. If someone reintroduces a
// hardcoded literal in the client Elm, this fails.
//
// config/app-config.json is git-ignored (it also holds real quiz answers, see
// config/app-config.example.json) so it isn't present on a fresh CI checkout --
// this real-content check only runs where a local copy exists. CI still gets
// full coverage of the underlying invariant from
// tests/unit/quiz-config-bundling.test.js's package.json build.files check,
// which asserts nothing under config/ is bundled into the client at all.
const APP_CONFIG_PATH = path.join(PROJECT_ROOT, 'config', 'app-config.json');

// Note: this must be a plain `if`, not `describe.skip` -- describe.skip still
// invokes its callback body (only the `test()`s inside are skipped), which
// would throw on the readFileSync below when the file is absent.
if (fs.existsSync(APP_CONFIG_PATH)) {
    describe('client bundle does not contain the win text', () => {
        const winText = JSON.parse(fs.readFileSync(APP_CONFIG_PATH, 'utf8')).winScreen;

        test('config/app-config.json has a non-empty winScreen to check against', () => {
            expect(typeof winText).toBe('string');
            expect(winText.length).toBeGreaterThan(0);
        });

        test('elm-client.js does not contain the win text', () => {
            const bundlePath = path.join(PROJECT_ROOT, 'elm-client.js');
            if (!fs.existsSync(bundlePath)) {
                throw new Error('elm-client.js not found — run: npm run build:client');
            }
            const bundle = fs.readFileSync(bundlePath, 'utf8');
            expect(bundle.includes(winText)).toBe(false);
            // Also check a distinctive substring, in case the exact phrasing changes.
            expect(bundle.includes('claim your reward')).toBe(false);
        });
    });
} else {
    test.skip('client bundle does not contain the win text (config/app-config.json absent locally)', () => {});
}

// Guards issue #54: quiz answers must live only on the server (in
// config/app-config.json's quizQuestions field, read server-side and never
// bundled). Unlike the win text above, answers were never compiled into Elm
// source as literals — they're loaded from config at runtime — so scanning
// elm-client.js for answer substrings isn't meaningful (and is prone to false
// positives: e.g. the real answer "Style" collides with Elm's compiled
// CSS-`style` runtime code). Since #70's review, nothing under config/ is
// bundled into the client at all (the client lists assets/songs/ directly
// instead) -- see tests/unit/quiz-config-bundling.test.js's package.json
// build.files check.
