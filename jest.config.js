module.exports = {
  testMatch: ['<rootDir>/tests/*.test.js'],
  collectCoverageFrom: ['server/**/*.js', 'client/**/*.js'],
  coverageDirectory: 'coverage/js',
  coverageReporters: ['text', 'lcov'],
};
