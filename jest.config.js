module.exports = {
  coverageDirectory: 'coverage/js',
  coverageReporters: ['text', 'lcov', 'json-summary'],
  projects: [
    {
      displayName: 'unit',
      testMatch: ['<rootDir>/tests/unit/**/*.test.js'],
      collectCoverageFrom: ['server/**/*.js', 'client/**/*.js', 'scripts/**/*.js'],
    },
    {
      displayName: 'integration',
      testMatch: ['<rootDir>/tests/integration/**/*.test.js'],
      globalSetup: '<rootDir>/tests/helpers/globalSetup.js',
      globalTeardown: '<rootDir>/tests/helpers/globalTeardown.js',
    },
  ],
};
