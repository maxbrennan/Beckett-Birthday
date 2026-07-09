'use strict';

const fs = require('fs');
const path = require('path');
const { PROJECT_ROOT } = require('../helpers/certPaths');

// Guards issue #27: the personalized win text must live only on the server (in
// builds.jsonl / config/win-screen.json read at deploy time), never compiled into the
// shipped client bundle. If someone reintroduces a hardcoded literal in the client Elm,
// this fails.
describe('client bundle does not contain the win text', () => {
    const winText = JSON.parse(
        fs.readFileSync(path.join(PROJECT_ROOT, 'config', 'win-screen.json'), 'utf8')
    ).text;

    test('config/win-screen.json has a non-empty win text to check against', () => {
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

// Guards issue #54: quiz answers must live only on the server (in
// config/quiz-questions.json, read server-side and never bundled). Unlike the
// win text above, answers were never compiled into Elm source as literals —
// they're loaded from config at runtime — so scanning elm-client.js for
// answer substrings isn't meaningful (and is prone to false positives: e.g.
// the real answer "Style" collides with Elm's compiled CSS-`style` runtime
// code). The actual leak vector is the bundled *config file*, guarded here
// and in tests/unit/quiz-manifest.test.js's package.json build.files check.
describe('client bundle config does not contain quiz answers', () => {
    test('config/quiz-manifest.json (the only quiz config the client bundles) carries no answers field', () => {
        const manifest = JSON.parse(
            fs.readFileSync(path.join(PROJECT_ROOT, 'config', 'quiz-manifest.json'), 'utf8')
        );
        manifest.forEach((entry) => {
            expect(entry).not.toHaveProperty('answers');
        });
    });
});
