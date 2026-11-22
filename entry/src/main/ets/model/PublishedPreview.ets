import { AgentStep, PreviewScreenshot, toolReceipts } from './Agent';
import { parseUiSurface, uiParts } from './InteractiveUi';
import { parseWebUi } from './WebUi';
import { referencePreviewId, previewReferenceTargets } from './PreviewReferences';
import { answerReferenceParts } from './AnswerReferences';
import { PublishedPanel, publishedPanels } from './PublishedPanel';

interface PreviewReceipt { path: string; title: string; version?: string; }
function previewReceipt(output: string): PreviewReceipt {
  const receipt = JSON.parse(output) as PreviewReceipt;
  if (!receipt || typeof receipt.path !== 'string' || !receipt.path || typeof receipt.title !== 'string') {
    throw new Error('Published preview receipt is missing its path or title');
  }
  return receipt;
}
export interface PreviewMessage { id: string; steps: AgentStep[]; }
export interface PublishedPreview {
  id: string;
  path: string;
  version?: string;
  title: string;
  content: string;
  step: number;
  surfaceOffset: number;
  superseded: boolean;
  screenshot?: PreviewScreenshot;
}
export interface PublishedAnswerPart { kind: string; content: string; key: string; preview?: PublishedPreview; panel?: PublishedPanel; }

export interface PublishedPreviewSource { text: string; language: string; }

export function publishedPreviewSource(preview: PublishedPreview): PublishedPreviewSource {
  const language = preview.path.slice(preview.path.lastIndexOf('.') + 1).toLowerCase();
  // Legacy publications saved JSONL directly inside the UI fence.
  if (language === 'jsonl') {
    const part = uiParts(preview.content, false).find(item => item.kind === 'ui');
    if (!part?.closed) { throw new Error('Published JSONL source is missing'); }
    return { text: part.content.slice(0, -1), language: 'json' };
  }
  const node = parseUiSurface(preview.content, '0').nodes.find(item => item.kind === 'web');
  if (!node?.data) { throw new Error('Published web source is missing'); }
  const spec = parseWebUi(node.data);
  return { text: language === 'js' ? spec.js : spec.html, language: language };
}

export function publishedAnswerParts(messageId: string, steps: AgentStep[], index: number, status: string, latest: string[]): PublishedAnswerPart[] {
  const step = steps[index];
  const final = status === 'complete' && index === steps.length - 1 && !step.tools.length && !step.uiValidation && !step.continuation;
  const parts = answerReferenceParts(step.content, status === 'generating');
  const panels = final && parts.some((part) => part.kind === 'panel' || part.kind === 'board') ? publishedPanels(steps) : [];
  const referencedPanels = Array.from(new Set<string>(parts.filter((part) => part.kind === 'panel' &&
    panels.some((item) => item.key === part.panelKey && !!item.target.panelId)).map((part) => part.panelKey as string)));
  const shown = new Set<string>();
  return parts.map((part, position): PublishedAnswerPart => {
    const key = index + ':' + position + ':' + part.kind;
    if (part.kind === 'text') { return { kind: 'text', content: part.content, key: key }; }
    if (!final) { return { kind: 'pending', content: '', key: key }; }
    if (part.kind === 'panel' || part.kind === 'board') {
      const target = panels.find((item) => item.key === part.panelKey && (part.kind === 'panel' ? !!item.target.panelId : !!item.target.boardId));
      if (!target) { return { kind: 'error', content: 'Life Panel reference is unavailable: ' + part.panelKey, key: key }; }
      const identity = part.kind + ':' + target.key;
      if (shown.has(identity)) { return { kind: 'pending', content: '', key: key }; }
      shown.add(identity);
      return { kind: 'panel', content: '', key: key, panel: { key: target.key, title: target.title, target: target.target,
        excludedPanelKeys: target.target.boardId ? referencedPanels : undefined } };
    }
    if (part.kind === 'invalid-panel' || part.kind === 'invalid') { return { kind: 'error', content: part.content, key: key }; }
    const target = previewReferenceTargets(steps).find((item) => item.previewId === part.previewId);
    if (!target) { return { kind: 'error', content: 'Preview reference is unavailable: ' + part.previewId, key: key }; }
    const previews = stepPreviews(messageId, steps[target.step], target.step, latest, true);
    return { kind: 'preview', content: '', key: key, preview: previews.find((item) => item.id === messageId + ':' + target.tool.call.id) };
  });
}

// Only successful publications replace an earlier revision. Keep distinct files independent.
export function latestPreviewIds(messages: PreviewMessage[]): string[] {
  const latest = new Map<string, string>();
  for (const message of messages) {
    for (const step of message.steps) {
      for (const tool of toolReceipts(step.tools)) {
        if (tool.status === 'complete' && tool.call.function.name === 'publish_preview' && tool.previewContent) {
          const receipt = previewReceipt(tool.output);
          latest.set(receipt.path, message.id + ':' + tool.call.id);
        }
      }
    }
  }
  return Array.from(latest.values());
}

export function stepPreviews(messageId: string, step: AgentStep, index: number, latest: string[], includeReferenced: boolean = false): PublishedPreview[] {
  if (!step.tools.length) { return []; }
  const result: PublishedPreview[] = [];
  let offset = uiParts(step.content, false).filter((part) => part.kind === 'ui').length;
  for (const tool of toolReceipts(step.tools)) {
    if (tool.status !== 'complete' || tool.call.function.name !== 'publish_preview' || !tool.previewContent) { continue; }
    const receipt = previewReceipt(tool.output);
    const referenced = referencePreviewId(tool) !== undefined;
    const id = messageId + ':' + tool.call.id;
    if (!referenced || includeReferenced) { result.push({ id: id, path: receipt.path, version: receipt.version, title: receipt.title, content: tool.previewContent, step: index,
      surfaceOffset: offset, superseded: !latest.includes(id), screenshot: tool.previewScreenshot });
    }
    // Preserve the original keys in stepDisplayContent, including multi-surface JSONL files.
    offset += uiParts(tool.previewContent, false).filter((part) => part.kind === 'ui').length;
  }
  return result;
}

// Presentation only. Model history uses step.content and the compact tool receipt.
export function stepDisplayContent(step: AgentStep): string {
  return [step.content].concat(toolReceipts(step.tools).filter((tool) => tool.status === 'complete' &&
    tool.call.function.name === 'publish_preview' && !!tool.previewContent && !referencePreviewId(tool)).map((tool) => tool.previewContent as string))
    .filter((content) => content.length > 0).join('\n\n');
}
