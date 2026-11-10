import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

let runtime: string = '';
let three: string = '';
let charts: WebChartAssets | undefined;

export interface WebChartAssets { script: string; font: string; }

export async function webChartAssets(context: common.UIAbilityContext): Promise<WebChartAssets> {
  if (charts) { return charts; }
  const resources = context.resourceManager;
  const decoder = new util.TextDecoder('utf-8', { fatal: true });
  const chart = decoder.decodeToString(await resources.getRawFileContent('interactive-web/chartjs.js'));
  const echarts = decoder.decodeToString(await resources.getRawFileContent('interactive-web/echarts.js'));
  const font = await resources.getRawFileContent('interactive-web/inter-latin.woff2');
  charts = { script: chart + '\n;\n' + echarts, font: new util.Base64Helper().encodeToStringSync(font) };
  return charts;
}
export async function webUiAssets(context: common.UIAbilityContext, withThree: boolean): Promise<string[]> {
  const decoder = new util.TextDecoder('utf-8', { fatal: true });
  if (!runtime) { runtime = decoder.decodeToString(await context.resourceManager.getRawFileContent('interactive-web/host.js')); }
  if (withThree && !three) { three = decoder.decodeToString(await context.resourceManager.getRawFileContent('interactive-web/three.bundle.js')); }
  return [runtime, withThree ? three : ''];
}
