import { t } from '../model/I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { MAX_SKILL_TEXT } from '../model/Skills';

// Read only the URI selected by the user and copy the text into the reviewed draft.
// No persistent external-folder grants or model-supplied filesystem paths are involved.
export async function readSkillImport(uri: string): Promise<string> {
  const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
  try {
    const maximum = 64 * 1024;
    const stat = await fs.stat(file.fd);
    if (!stat.isFile() || stat.size > maximum) { throw new Error(t("请选择不超过 64 KiB 的普通 UTF-8 文本文件。")); }
    const bytes = new Uint8Array(maximum + 1);
    let length = 0;
    while (length < bytes.length) {
      const buffer = new ArrayBuffer(bytes.length - length);
      const count = await fs.read(file.fd, buffer);
      if (count === 0) { break; }
      bytes.set(new Uint8Array(buffer, 0, count), length);
      length += count;
    }
    if (length > maximum) { throw new Error(t("导入文件超过 64 KiB。")); }
    const text = length === 0 ? '' : new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes.slice(0, length));
    if (text.length > MAX_SKILL_TEXT || text.includes('\u0000')) { throw new Error(t("导入文件必须是最多 32000 字符的文本。")); }
    return text;
  } finally { await fs.close(file); }
}
