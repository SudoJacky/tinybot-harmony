import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

import { CredentialVault } from './ProfileSettings';

const MISSING_API_KEY: string = '无法读取已保存的 API Key，请进入设置，编辑对应模型服务，重新填写 API Key 并保存。';

export class CredentialStore implements CredentialVault {
  async read(alias: string): Promise<string> {
    if (alias.length === 0) {
      return '';
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let result: asset.AssetMap[];
    try {
      result = await asset.query(query);
    } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) {
        throw new Error(MISSING_API_KEY);
      }
      throw error as Error;
    }
    if (result.length !== 1) {
      throw new Error(MISSING_API_KEY);
    }
    return new util.TextDecoder('utf-8').decodeToString(result[0].get(asset.Tag.SECRET) as Uint8Array);
  }

  async write(alias: string, secret: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    const encoder = new util.TextEncoder();
    attributes.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
    attributes.set(asset.Tag.SECRET, encoder.encodeInto(secret));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    await asset.add(attributes);
  }

  async remove(alias: string): Promise<void> {
    if (alias.length === 0) {
      return;
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    try {
      await asset.remove(query);
    } catch (error) {
      if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) {
        throw error as Error;
      }
    }
  }
  async update(alias: string, secret: string): Promise<void> {
    const query: asset.AssetMap = new Map(); const attributes: asset.AssetMap = new Map(); const encoder = new util.TextEncoder();
    query.set(asset.Tag.ALIAS, encoder.encodeInto(alias)); attributes.set(asset.Tag.SECRET, encoder.encodeInto(secret));
    await asset.update(query, attributes);
  }
}
