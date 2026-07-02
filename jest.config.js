module.exports = {
  testMatch: ['<rootDir>/tests/*.test.js'],
  collectCoverageFrom: ['server/**/*.js', 'client/**/*.js', 'scripts/**/*.js'],
  coverageDirectory: 'coverage/js',
  coverageReporters: ['text', 'lcov'],
  globalSetup: '<rootDir>/tests/helpers/globalSetup.js',
  globalTeardown: '<rootDir>/tests/helpers/globalTeardown.js',
};
