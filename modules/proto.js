require('child_process').spawnSync('bash', ['../commands/buildunbundledassets.sh']);
require('../shared/assets/js/standalone/global');
require('../shared/assets/js/cyph/protos');

module.exports	= Index;
global.Index	= undefined;
