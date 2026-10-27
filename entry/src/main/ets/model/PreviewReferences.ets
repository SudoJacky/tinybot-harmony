import { AgentStep, ToolExecution, toolReceipts } from './Agent';

export interface PreviewReferencePart { kind: string; content: string; previewId: string; }
interface ReferenceReceipt { previewId?: string; reference?: string; path: string; title: string; }
export interface PreviewReferenceTarget { previewId: string; reference: string; path: string; title: string; tool: ToolExecution; step: number; }
export function previewReference(id: string): string { return '[[tinybot-preview:' + id + ']]'; }
export function referencePreviewId(tool: ToolExecution): string | undefined {
  if (tool.status !== 'complete' || tool.call.function.name !== 'publish_preview' || !tool.previewContent) { return undefined; }
  const receipt = JSON.parse(tool.output) as ReferenceReceipt;
  if (receipt.previewId === undefined) { return undefined; }
  if (typeof receipt.previewId !== 'string' || !/^pv_[A-Za-z0-9_-]{1,77}$/.test(receipt.previewId) ||
    receipt.reference !== previewReference(receipt.previewId)) { throw new Error('Invalid published preview reference'); }
  return receipt.previewId;
}
export function previewReferenceTargets(steps: AgentStep[]): PreviewReferenceTarget[] {
  const result: PreviewReferenceTarget[] = [];
  steps.forEach((step, index) => {
    for (const tool of toolReceipts(step.tools)) {
      const id = referencePreviewId(tool);
      if (!id) { continue; }
      const receipt = JSON.parse(tool.output) as ReferenceReceipt;
      result.push({ previewId: id, reference: previewReference(id), path: receipt.path, title: receipt.title, tool: tool, step: index });
    }
  });
  return result;
}

// A standalone block only. Code fences and escaped/example text remain ordinary Markdown.
export function previewReferenceParts(content: string, streaming: boolean = false): PreviewReferencePart[] {
  const parts: PreviewReferencePart[] = [];
  const lines = content.split('\n');
  let text = '', fence = '', fenceLength = 0;
  const flush = (): void => {
    if (text.trim()) { parts.push({ kind: 'text', content: text, previewId: '' }); }
    text = '';
  };
  lines.forEach((line, index) => {
    const delimiter = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (delimiter) {
      if (!fence) { fence = delimiter[1][0]; fenceLength = delimiter[1].length; }
      else if (delimiter[1][0] === fence && delimiter[1].length >= fenceLength && !delimiter[2].trim()) { fence = ''; }
      text += line + (index < lines.length - 1 ? '\n' : ''); return;
    }
    const value = line.trim();
    const block = !fence && !/^( {4}|\t)/.test(line);
    if (block && value.startsWith('[[tinybot-preview:')) {
      flush();
      const match = value.match(/^\[\[tinybot-preview:(pv_[A-Za-z0-9_-]{1,77})\]\]$/);
      if (match) { parts.push({ kind: 'preview', content: '', previewId: match[1] }); }
      else if (!streaming) { parts.push({ kind: 'invalid', content: 'Invalid preview reference', previewId: '' }); }
      return;
    }
    if (block && streaming && value.length >= 2 && '[[tinybot-preview:'.startsWith(value)) { flush(); return; }
    text += line + (index < lines.length - 1 ? '\n' : '');
  });
  flush(); return parts;
}

// Validate only the no-tool answer. Successful tool effects are never repeated for a wording repair.
export function previewReferenceError(steps: AgentStep[], content: string): string {
  const targets = previewReferenceTargets(steps);
  const latest = new Map<string, PreviewReferenceTarget>();
  targets.forEach((target) => latest.set(target.path, target));
  const ids = new Set<string>();
  const problems: string[] = [];
  for (const part of previewReferenceParts(content)) {
    if (part.kind === 'invalid') { problems.push('Malformed reference.'); }
    if (part.kind !== 'preview') { continue; }
    if (!targets.some((target) => target.previewId === part.previewId)) { problems.push('Unknown or unavailable preview: ' + part.previewId); }
    if (ids.has(part.previewId)) { problems.push('Duplicate preview reference: ' + part.previewId); }
    ids.add(part.previewId);
  }
  for (const target of Array.from(latest.values())) {
    if (!ids.has(target.previewId)) { problems.push('Missing preview reference: ' + target.reference); }
  }
  if (!problems.length) { return ''; }
  const diagnostic = 'PREVIEW_REFERENCE_INVALID: ' + problems.join(' ') +
    '\nRewrite the final answer using each required reference on its own line, outside code fences. ' +
    'Reuse these successful snapshots; do not republish or rewrite files. Available references: ' +
    Array.from(latest.values()).map((target) => target.reference).join(', ');
  // AgentStep.uiValidation has an 8,000-character persistence budget.
  return diagnostic.length <= 7900 ? diagnostic : diagnostic.slice(0, 7700) +
    '\nDiagnostic truncated; read successful publication receipts for all available references.';
}
