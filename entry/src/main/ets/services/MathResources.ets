import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { mathHost } from '../model/MathContent';

// Shared across formula paragraphs; load lazily so ordinary chat startup is unchanged.
let cachedHost: Promise<string> | undefined;
export function loadMathHost(context: common.UIAbilityContext): Promise<string> {
  if (!cachedHost) {
    cachedHost = Promise.all(['katex.min.js', 'katex.min.css', 'host.js'].map(async (name: string): Promise<string> => {
      const bytes = await context.resourceManager.getRawFileContent('math/' + name);
      return util.TextDecoder.create('utf-8').decodeWithStream(bytes);
    })).then((parts: string[]): string => mathHost(parts[0], parts[1], parts[2]));
  }
  return cachedHost;
}
