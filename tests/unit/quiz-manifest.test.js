'use strict';

const fs = require('fs');
const path = require('path');
const { PROJECT_ROOT } = require('../helpers/certPaths');

// Guards issue #54: config/quiz-manifest.json is the only quiz config the
// client ever loads/bundles, so it must never carry an `answers` field, and
// must stay index-aligned with config/quiz-questions.example.json (the
// tracked stand-in for the real, gitignored config/quiz-questions.json) so
// the two can't silently drift apart.

describe('config/quiz-manifest.json', () => {
    const manifest = JSON.parse(
        fs.readFileSync(path.join(PROJECT_ROOT, 'config', 'quiz-manifest.json'), 'utf8')
    );
    const example = JSON.parse(
        fs.readFileSync(path.join(PROJECT_ROOT, 'config', 'quiz-questions.example.json'), 'utf8')
    );

    test('is non-empty', () => {
        expect(manifest.length).toBeGreaterThan(0);
    });

    test('no entry carries an answers field', () => {
        manifest.forEach((entry) => {
            expect(entry).not.toHaveProperty('answers');
            expect(Object.keys(entry)).toEqual(['song']);
        });
    });

    test('has the same length as config/quiz-questions.example.json', () => {
        expect(manifest.length).toBe(example.length);
    });

    test('song filenames match config/quiz-questions.example.json in the same order', () => {
        expect(manifest.map((e) => e.song)).toEqual(example.map((e) => e.song));
    });
});

describe('package.json build.files excludes config/quiz-questions.json', () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(PROJECT_ROOT, 'package.json'), 'utf8'));

    test('the real, gitignored answers file is negated out of the Electron bundle', () => {
        expect(pkg.build.files).toContain('!config/quiz-questions.json');
    });
});
