module.exports = {
  apps: [
    {
      name: 'birthday-server',
      script: 'server/index.js',
      autorestart: false,
    },
    {
      name: 'birthday-client',
      script: 'electron',
      args: '.',
      autorestart: false,
    },
  ],
};
