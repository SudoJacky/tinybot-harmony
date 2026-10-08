import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

let runtime: string = '';
let three: string = '';
export async function webUiAssets(context: common.UIAbilityContext, withThree: boolean): Promise<string[]> {
  const decoder = new util.TextDecoder('utf-8', { fatal: true });
  if (!runtime) { runtime = decoder.decodeToString(await context.resourceManager.getRawFileContent('interactive-web/host.js')); }
  if (withThree && !three) { three = decoder.decodeToString(await context.resourceManager.getRawFileContent('interactive-web/three.bundle.js')); }
  return [runtime, withThree ? three : ''];
}
