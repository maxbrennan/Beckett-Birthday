'use strict';

const fs = require('fs');
const path = require('path');
const { PROJECT_ROOT } = require('../helpers/certPaths');

// Guards issue #54 (and #70's review): nothing under config/ is bundled into the
// client at all -- the client discovers songs by listing assets/songs/ directly
// (client/bridge.js's readDir port + Game.Quiz.songOrder) and never reads a
// `song` field or any quiz config file. config/app-config.example.json (the
// tracked stand-in for the real, gitignored config/app-config.json) should
// therefore carry no `song` field on any quizQuestions entry either -- a
// question's array position is the only thing that ties it to a numbered file
// in assets/songs/.

describe('config/app-config.example.json', () => {
    const example = JSON.parse(
        fs.readFileSync(path.join(PROJECT_ROOT, 'config', 'app-config.example.json'), 'utf8')
    );

    test('has a non-empty appName', () => {
        expect(typeof example.appName).toBe('string');
        expect(example.appName.length).toBeGreaterThan(0);
    });

    test('has a non-empty quizQuestions list', () => {
        expect(example.quizQuestions.length).toBeGreaterThan(0);
    });

    test('no quizQuestions entry carries a song field -- order alone ties a question to its numbered file', () => {
        example.quizQuestions.forEach((entry) => {
            expect(entry).not.toHaveProperty('song');
            expect(Object.keys(entry)).toEqual(['answers']);
        });
    });

    test('has a non-empty winScreen', () => {
        expect(typeof example.winScreen).toBe('string');
        expect(example.winScreen.length).toBeGreaterThan(0);
    });

    test('has a boolean iqSkipOfferEnabled', () => {
        expect(typeof example.iqSkipOfferEnabled).toBe('boolean');
    });
});

describe('package.json build.files excludes config/ entirely', () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(PROJECT_ROOT, 'package.json'), 'utf8'));

    test('no config/ glob is bundled into the Electron client', () => {
        pkg.build.files.forEach((pattern) => {
            expect(pattern.replace(/^!/, '')).not.toMatch(/^config\//);
        });
    });
});
