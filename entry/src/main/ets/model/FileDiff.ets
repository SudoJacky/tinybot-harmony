export interface FileDiffRow {
  kind: string;
  text: string;
  oldLine: number;
  newLine: number;
  noNewline: boolean;
}
export interface FileDiff {
  path: string;
  added: number;
  removed: number;
  created: boolean;
  rows: FileDiffRow[];
}

function lines(text: string): string[] { return text.match(/[^\n]*\n|[^\n]+$/g) || []; }

// Strip common edges before LCS. Bound its matrix so a large replacement cannot stall the UI.
// Above the budget the remaining block is represented faithfully as a replacement.
export function fileDiff(path: string, before: string, after: string, created: boolean = false): FileDiff {
  const old = lines(before); const next = lines(after);
  const result: FileDiff = { path: path, added: 0, removed: 0, created: created, rows: [] };
  const rows: FileDiffRow[] = [];
  let oldLine = 1; let newLine = 1;
  const append = (kind: string, text: string): void => {
    rows.push({ kind: kind, text: text.replace(/\r?\n$/, ''), oldLine: kind === 'added' ? 0 : oldLine,
      newLine: kind === 'removed' ? 0 : newLine, noNewline: !text.endsWith('\n') });
    if (kind !== 'added') { oldLine++; }
    if (kind !== 'removed') { newLine++; }
    if (kind === 'added') { result.added++; }
    if (kind === 'removed') { result.removed++; }
  };
  let start = 0;
  while (start < old.length && start < next.length && old[start] === next[start]) { append('context', old[start]); start++; }
  let oldEnd = old.length; let newEnd = next.length;
  while (oldEnd > start && newEnd > start && old[oldEnd - 1] === next[newEnd - 1]) { oldEnd--; newEnd--; }
  const height = oldEnd - start; const width = newEnd - start;
  if (height > 0 && width > 0 && (height + 1) * (width + 1) <= 500000) {
    const stride = width + 1;
    const table = new Uint32Array((height + 1) * stride);
    for (let i = height - 1; i >= 0; i--) {
      for (let j = width - 1; j >= 0; j--) {
        table[i * stride + j] = old[start + i] === next[start + j] ? table[(i + 1) * stride + j + 1] + 1 :
          Math.max(table[(i + 1) * stride + j], table[i * stride + j + 1]);
      }
    }
    let i = 0; let j = 0;
    while (i < height || j < width) {
      if (i < height && j < width && old[start + i] === next[start + j]) { append('context', old[start + i]); i++; j++; }
      else if (i < height && (j === width || table[(i + 1) * stride + j] >= table[i * stride + j + 1])) {
        append('removed', old[start + i]); i++;
      } else { append('added', next[start + j]); j++; }
    }
  } else {
    for (let i = start; i < oldEnd; i++) { append('removed', old[i]); }
    for (let j = start; j < newEnd; j++) { append('added', next[j]); }
  }
  for (let i = oldEnd; i < old.length; i++) { append('context', old[i]); }
  if (result.added + result.removed === 0) { return result; }
  // Persist only changes and three surrounding context lines, not another full file snapshot.
  const keep = new Set<number>();
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].kind === 'context') { continue; }
    for (let j = Math.max(0, i - 3); j <= Math.min(rows.length - 1, i + 3); j++) { keep.add(j); }
  }
  let skipped = false;
  for (let i = 0; i < rows.length; i++) {
    if (keep.has(i)) { result.rows.push(rows[i]); skipped = false; }
    else if (!skipped) {
      result.rows.push({ kind: 'gap', text: '…', oldLine: 0, newLine: 0, noNewline: false }); skipped = true;
    }
  }
  return result;
}

export function fileDiffText(diff: FileDiff): string {
  return '--- ' + diff.path + '\n+++ ' + diff.path + '\n' + diff.rows.map((row: FileDiffRow): string =>
    (row.kind === 'added' ? '+' : row.kind === 'removed' ? '-' : ' ') + row.text +
      (row.noNewline ? '\n\\ No newline at end of file' : '')).join('\n');
}
