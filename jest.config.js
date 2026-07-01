module.exports = {
  testMatch: ['<rootDir>/tests/*.test.js'],
  collectCoverageFrom: ['server/**/*.js', 'client/**/*.js', 'scripts/**/*.js'],
  coverageDirectory: 'coverage/js',
  coverageReporters: ['text', 'lcov'],
};
