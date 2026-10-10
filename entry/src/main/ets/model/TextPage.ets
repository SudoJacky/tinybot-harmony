export const MAX_READ_LINES: number = 2000;
export const MAX_READ_BYTES: number = 50 * 1024;

export interface TextPage {
  content: string;
  startLine: number;
  totalLines: number;
  truncated: boolean;
  nextOffset?: number;
  nextColumn?: number;
}

// Columns are 1-based UTF-16 positions. A cursor never splits a surrogate pair.
// Long individual lines can be continued too; Harmony has no shell fallback.
export function textPage(content: string, offset: number = 1, limit: number = MAX_READ_LINES, column: number = 1): TextPage {
  if (!Number.isSafeInteger(offset) || offset < 1 || !Number.isSafeInteger(limit) || limit < 1 ||
    !Number.isSafeInteger(column) || column < 1) { throw new Error('offset, limit and column must be positive integers.'); }
  const lines = content.split('\n');
  if (offset > lines.length) { throw new Error('offset is beyond the end of the file.'); }
  const first = lines[offset - 1];
  if (column > first.length + 1 || (column > 1 && first.charCodeAt(column - 1) >= 0xdc00 &&
    first.charCodeAt(column - 1) <= 0xdfff && first.charCodeAt(column - 2) >= 0xd800 && first.charCodeAt(column - 2) <= 0xdbff)) {
    throw new Error('column is outside the line or splits a Unicode character.');
  }
  const result: TextPage = { content: '', startLine: offset, totalLines: lines.length, truncated: false };
  const chunks: string[] = [];
  let bytes = 0;
  const end = Math.min(lines.length, offset - 1 + Math.min(limit, MAX_READ_LINES));
  for (let index = offset - 1; index < end; index++) {
    const line = lines[index];
    const start = index === offset - 1 ? column - 1 : 0;
    let position = start;
    while (position < line.length) {
      const code = line.charCodeAt(position);
      const paired = code >= 0xd800 && code <= 0xdbff && position + 1 < line.length &&
        line.charCodeAt(position + 1) >= 0xdc00 && line.charCodeAt(position + 1) <= 0xdfff;
      const size = paired ? 4 : code < 0x80 ? 1 : code < 0x800 ? 2 : 3;
      if (bytes + size > MAX_READ_BYTES) { break; }
      bytes += size; position += paired ? 2 : 1;
    }
    chunks.push(line.slice(start, position));
    if (position < line.length) {
      result.nextOffset = index + 1; result.nextColumn = position + 1;
      break;
    }
    if (index + 1 < lines.length) {
      // Include separators in the budget, so joining successive pages is lossless.
      if (bytes === MAX_READ_BYTES) {
        result.nextOffset = index + 1; result.nextColumn = position + 1;
        break;
      }
      chunks.push('\n'); bytes++;
      if (index + 1 === end) { result.nextOffset = index + 2; result.nextColumn = 1; }
    }
  }
  result.content = chunks.join(''); result.truncated = result.nextOffset !== undefined;
  return result;
}
