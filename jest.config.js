module.exports = {
  coverageDirectory: 'coverage/js',
  coverageReporters: ['text', 'lcov', 'json-summary'],
  projects: [
    {
      displayName: 'unit',
      testMatch: ['<rootDir>/tests/unit/**/*.test.js'],
      collectCoverageFrom: ['server/**/*.js', 'client/**/*.js', 'scripts/**/*.js'],
      // elm-server.js/elm-client.js are compiled Elm build artifacts required transitively
      // by server/index.js and bridge.js — they're not hand-written JS and would swamp
      // the coverage percentage with thousands of generated, untestable lines.
      coveragePathIgnorePatterns: ['/node_modules/', '<rootDir>/elm-server\\.js$', '<rootDir>/elm-client\\.js$'],
    },
    {
      displayName: 'integration',
      testMatch: ['<rootDir>/tests/integration/**/*.test.js'],
      globalSetup: '<rootDir>/tests/helpers/globalSetup.js',
      globalTeardown: '<rootDir>/tests/helpers/globalTeardown.js',
    },
  ],
};
