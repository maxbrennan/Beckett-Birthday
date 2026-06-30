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
      args: 'electron .',
      autorestart: false,
      env: { DEV: 'false' },
      env_dev: { DEV: 'true' },
    },
  ],
};
