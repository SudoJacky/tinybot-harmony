import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

import { CredentialVault } from './ProfileSettings';
import { BackupChanges } from '../model/BackupChanges';
import { DetailedError } from '../model/DetailedError';
import { t } from '../model/I18n';

export class CredentialStore implements CredentialVault {
  async read(alias: string): Promise<string> {
    if (alias.length === 0) {
      return '';
    }
    const secret = await this.readOptional(alias);
    if (secret === undefined) {
      throw new DetailedError(t('无法读取已保存的 API Key，请进入设置，编辑对应模型服务，重新填写 API Key 并保存。'),
        { code: asset.ErrorCode.NOT_FOUND, stage: 'credential_read' });
    }
    return secret;
  }

  async readOptional(alias: string): Promise<string | undefined> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let result: asset.AssetMap[];
    try {
      result = await asset.query(query);
    } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) {
        return undefined;
      }
      throw error as Error;
    }
    if (!result.length) { return undefined; }
    if (result.length !== 1) { throw new Error(t('安全存储返回了重复的凭据记录。')); }
    return new util.TextDecoder('utf-8').decodeToString(result[0].get(asset.Tag.SECRET) as Uint8Array);
  }

  async listAliases(group: string): Promise<string[]> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.DATA_LABEL_NORMAL_1, new util.TextEncoder().encodeInto(group));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    query.set(asset.Tag.RETURN_LIMIT, 10);
    const aliases: string[] = [];
    const decoder = new util.TextDecoder('utf-8');
    while (true) {
      query.set(asset.Tag.RETURN_OFFSET, aliases.length);
      let rows: asset.AssetMap[];
      try { rows = await asset.query(query); }
      catch (error) {
        if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) { return aliases; }
        throw error as Error;
      }
      for (const row of rows) { aliases.push(decoder.decodeToString(row.get(asset.Tag.ALIAS) as Uint8Array)); }
      if (rows.length < 10) { return aliases; }
    }
  }

  async write(alias: string, secret: string, group: string = ''): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    const encoder = new util.TextEncoder();
    attributes.set(asset.Tag.ALIAS, encoder.encodeInto(alias));
    attributes.set(asset.Tag.SECRET, encoder.encodeInto(secret));
    if (group) { attributes.set(asset.Tag.DATA_LABEL_NORMAL_1, encoder.encodeInto(group)); }
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    await asset.add(attributes);
    BackupChanges.revision++;
  }

  async remove(alias: string): Promise<void> {
    if (alias.length === 0) {
      return;
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    try {
      await asset.remove(query);
      BackupChanges.revision++;
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
    BackupChanges.revision++;
  }
}
