module.exports = {
  apps: [
    {
      name: 'birthday-server',
      script: 'server/index.js',
      autorestart: false,
      env: { DEV: 'false' },
      env_dev: { DEV: 'true' },
    },
    {
      name: 'birthday-client',
      script: 'npx',
      // npm's Windows shim for the electron bin is electron.cmd; macOS/Linux use the plain
      // `electron` bin, which has no .cmd counterpart.
      args: process.platform === 'win32' ? 'electron.cmd .' : 'electron .',
      autorestart: false,
      env: { DEV: 'false' },
      env_dev: { DEV: 'true' },
    },
  ],
};
