import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export async function contentVersion(content: string): Promise<string> {
  const hash = cryptoFramework.createMd('SHA256');
  // The device encoder returns undefined for an empty string.
  if (content.length > 0) { await hash.update({ data: new util.TextEncoder().encodeInto(content) }); }
  return new util.Base64Helper().encodeToStringSync((await hash.digest()).data);
}
