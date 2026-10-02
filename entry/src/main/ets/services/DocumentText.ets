import { t } from '../model/I18n';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { pdfService } from '@kit.PDFKit';
interface ZipEntry { name: string; method: number; packed: number; size: number; offset: number; }
function xmlText(xml: string): string {
  return xml.replace(/<\/(?:w:p|a:p|row)>/g, '\n').replace(/<[^>]*>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#(x[0-9a-f]+|[0-9]+);/gi, (_match: string, value: string) => {
    const code = value[0].toLowerCase() === 'x' ? parseInt(value.slice(1), 16) : parseInt(value, 10);
    return code >= 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '';
  }).replace(/&amp;/g, '&');
}
export function zipEntries(bytes: ArrayBuffer): ZipEntry[] {
  const view = new DataView(bytes); let end = bytes.byteLength - 22;
  while (end >= Math.max(0, bytes.byteLength - 65557) && view.getUint32(end, true) !== 0x06054b50) { end--; }
  if (end < 0 || view.getUint32(end, true) !== 0x06054b50) { throw new Error(t("Office 文件不是有效 ZIP 文档。")); }
  const count = view.getUint16(end + 10, true); let offset = view.getUint32(end + 16, true); let size = 0;
  if (count > 3000 || view.getUint16(end + 4, true) !== 0 || view.getUint16(end + 6, true) !== 0) { throw new Error(t("不支持分卷或超大 Office 文档。")); }
  const entries: ZipEntry[] = [];
  for (let i = 0; i < count; i++) {
    if (offset + 46 > bytes.byteLength || view.getUint32(offset, true) !== 0x02014b50 || (view.getUint16(offset + 8, true) & 1)) { throw new Error(t("Office 压缩目录无效或文档已加密。")); }
    const nameLength = view.getUint16(offset + 28, true); const length = 46 + nameLength + view.getUint16(offset + 30, true) + view.getUint16(offset + 32, true);
    if (offset + length > bytes.byteLength) { throw new Error(t("Office 文档不完整。")); }
    const entry: ZipEntry = { name: new util.TextDecoder('utf-8', { fatal: true }).decodeToString(new Uint8Array(bytes.slice(offset + 46, offset + 46 + nameLength))),
      method: view.getUint16(offset + 10, true), packed: view.getUint32(offset + 20, true), size: view.getUint32(offset + 24, true), offset: view.getUint32(offset + 42, true) };
    if (/^(word\/document\.xml|ppt\/slides\/slide\d+\.xml|xl\/(sharedStrings\.xml|worksheets\/sheet\d+\.xml))$/.test(entry.name)) {
      size += entry.size; if (size > 8 * 1024 * 1024 || entry.size > 2 * 1024 * 1024) { throw new Error(t("Office 文档文字数据过大。")); } entries.push(entry);
    }
    offset += length;
  }
  return entries;
}
async function unzipEntry(bytes: ArrayBuffer, entry: ZipEntry): Promise<string> {
  const view = new DataView(bytes); const offset = entry.offset;
  if (offset + 30 > bytes.byteLength || view.getUint32(offset, true) !== 0x04034b50) { throw new Error(t("Office 压缩项无效。")); }
  const start = offset + 30 + view.getUint16(offset + 26, true) + view.getUint16(offset + 28, true);
  if (start + entry.packed > bytes.byteLength) { throw new Error(t("Office 压缩项不完整。")); }
  let result = bytes.slice(start, start + entry.packed);
  if (entry.method === 8) {
    const zip = zlib.createZipSync(); const output = new ArrayBuffer(entry.size + 1);
    const stream: zlib.ZStream = { nextIn: result, availableIn: result.byteLength, nextOut: output, availableOut: output.byteLength };
    await zip.inflateInit2(stream, -15);
    try {
      const status = await zip.inflate(stream, zlib.CompressFlushMode.FINISH); const final = await zip.getZStream();
      if (status !== zlib.ReturnStatus.STREAM_END || final.totalOut !== entry.size) { throw new Error(t("Office 解压结果大小不一致。")); }
      result = output.slice(0, entry.size);
    } finally { await zip.inflateEnd(stream); }
  } else if (entry.method !== 0 || result.byteLength !== entry.size) { throw new Error(t("不支持此 Office 压缩方式。")); }
  return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(new Uint8Array(result));
}
export async function officeText(bytes: ArrayBuffer): Promise<string> {
  const entries = zipEntries(bytes).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
  const shared: string[] = []; const strings = entries.find((item) => item.name === 'xl/sharedStrings.xml');
  if (strings) { const xml = await unzipEntry(bytes, strings); for (const match of xml.match(/<si[\s>][\s\S]*?<\/si>/g) || []) { shared.push(xmlText(match)); } }
  const sections: string[] = [];
  for (const entry of entries.filter((item) => item.name !== 'xl/sharedStrings.xml')) {
    const xml = await unzipEntry(bytes, entry); let text = '';
    if (entry.name.startsWith('xl/')) {
      for (const cell of xml.match(/<c\b[^>]*>[\s\S]*?<\/c>/g) || []) {
        const address = /\br="([^"]+)"/.exec(cell)?.[1] || '?'; const value = /<v>([\s\S]*?)<\/v>/.exec(cell)?.[1] || '';
        const content = /\bt="s"/.test(cell) ? shared[Number(value)] || '' : /\bt="inlineStr"/.test(cell) ? xmlText(cell) : xmlText(value);
        text += address + ': ' + content + '\n';
      }
    } else { text = xmlText(xml); }
    sections.push('[' + entry.name + ']\n' + text);
  }
  const text = sections.join('\n\n');
  if (!text.trim()) { throw new Error(t("文档没有可提取的文字。")); }
  return text.length > 31000 ? text.slice(0, 31000) + '\n[文字超过上限，以下内容未提取]' : text;
}
export function pdfText(path: string): string {
  const document = new pdfService.PdfDocument();
  try {
    document.loadDocument(path); const count = document.getPageCount(); let text = '';
    for (let i = 0; i < Math.min(count, 100); i++) {
      const page = document.getPage(i);
      try { text += '\n[第 ' + (i + 1) + ' 页]\n' + page.getTextContent(); } finally { page.release(); }
      if (text.length > 31000) { return text.slice(0, 31000) + '\n[文字超过上限，以下内容未提取]'; }
    }
    if (count > 100) { text += '\n[仅提取前 100 页]'; }
    if (!text.replace(/\[第 \d+ 页\]/g, '').trim()) { throw new Error(t("PDF 没有可提取的文字，扫描件请使用图片输入。")); }
    return text;
  } finally { document.releaseDocument(); }
}
