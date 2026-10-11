import { t } from './I18n';

export interface TextEdit { oldText: string; newText: string; }
interface LocatedEdit { start: number; end: number; replacement: string; unchanged: boolean; }

export function validateEdits(edits: TextEdit[]): void {
  if (!Array.isArray(edits) || edits.length === 0 || edits.length > 32) {
    throw new Error(t('edits 必须包含 1–32 项编辑。'));
  }
  edits.forEach((edit: TextEdit, index: number) => {
    if (!edit || Array.isArray(edit) || typeof edit.oldText !== 'string' || !edit.oldText ||
      typeof edit.newText !== 'string' || Object.keys(edit).some((key: string) => !['oldText', 'newText'].includes(key))) {
      throw new Error(t('第 {0} 项编辑需要非空 oldText 和字符串 newText。', [index + 1]));
    }
  });
}

// Every edit addresses the same original. Only CRLF/LF are equivalent; whitespace stays exact.
export function applyTextEdits(content: string, edits: TextEdit[]): string {
  validateEdits(edits);
  const bom = content.startsWith('\uFEFF') ? '\uFEFF' : '';
  const original = content.slice(bom.length);
  const normalized = original.replace(/\r\n/g, '\n');
  const crlf = original.length - normalized.length;
  const newlines = normalized.split('\n').length - 1;
  const ending = crlf > newlines / 2 ? '\r\n' : '\n';
  const located: LocatedEdit[] = edits.map((edit: TextEdit, index: number): LocatedEdit => {
    const oldText = edit.oldText.replace(/\r\n/g, '\n');
    const newText = edit.newText.replace(/\r\n/g, '\n');
    const start = normalized.indexOf(oldText);
    if (start < 0) { throw new Error(t('第 {0} 项编辑：', [index + 1]) + t('原文不存在，请重新读取文件。')); }
    if (normalized.indexOf(oldText, start + 1) >= 0) {
      throw new Error(t('第 {0} 项编辑：', [index + 1]) + t('原文匹配多处，请提供更多上下文。'));
    }
    return { start: start, end: start + oldText.length, replacement: newText.replace(/\n/g, ending), unchanged: oldText === newText };
  }).sort((a: LocatedEdit, b: LocatedEdit) => a.start - b.start);
  for (let i = 1; i < located.length; i++) {
    if (located[i].start < located[i - 1].end) { throw new Error(t('编辑范围重叠，请合并为一项编辑。')); }
  }
  // Map sorted normalized offsets back to original UTF-16 offsets without rewriting untouched lines.
  let raw = 0; let normalizedOffset = 0; let previous = 0;
  const parts: string[] = [bom];
  const rawOffset = (target: number): number => {
    while (normalizedOffset < target) {
      raw += original[raw] === '\r' && original[raw + 1] === '\n' ? 2 : 1;
      normalizedOffset++;
    }
    return raw;
  };
  for (const edit of located) {
    const start = rawOffset(edit.start); const end = rawOffset(edit.end);
    parts.push(original.slice(previous, start), edit.unchanged ? original.slice(start, end) : edit.replacement);
    previous = end;
  }
  parts.push(original.slice(previous));
  return parts.join('');
}
