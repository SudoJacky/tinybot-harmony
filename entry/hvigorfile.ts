// @ts-nocheck – Template file, only used when copied into a project directory
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { hapTasks, OhosPluginId } from '@ohos/hvigor-ohos-plugin';

const runtimes = ['tinybot-node', 'tinybot-sh'].map(name => 'libs/arm64-v8a/' + name);

export default {
  system: hapTasks,
  plugins: [{
    pluginId: 'tinybot-desktop-runtimes',
    apply(node) {
      node.afterNodeEvaluate(() => {
        const present = runtimes.filter(path => existsSync(join(__dirname, path)));
        if (!present.length) { return; }
        if (present.length !== runtimes.length) {
          throw new Error('Both desktop runtimes must be staged. Run scripts/build-desktop-runtimes.sh.');
        }
        const context = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN);
        const profile = context.getModuleJsonOpt();
        profile.module.executableBinaryPaths = present.map(path => ({ path }));
        context.setModuleJsonOpt(profile);
      });
    }
  }],
};
