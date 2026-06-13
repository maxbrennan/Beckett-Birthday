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
      script: 'electron',
      args: '.',
      autorestart: false,
      env: { DEV: 'false' },
      env_dev: { DEV: 'true' },
    },
  ],
};
