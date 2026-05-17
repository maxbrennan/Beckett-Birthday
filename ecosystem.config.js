module.exports = {
  apps: [
    {
      name: 'birthday-server',
      script: 'birthday-server.js',
      autorestart: false,
    },
    {
      name: 'birthday-client',
      script: './node_modules/.bin/electron',
      args: '.',
      interpreter: 'none',
      autorestart: false,
    },
  ],
};
