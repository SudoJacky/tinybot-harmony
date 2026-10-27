import { AgentStep, PreviewScreenshot, toolReceipts } from './Agent';
import { uiParts } from './InteractiveUi';
import { referencePreviewId, previewReferenceParts, previewReferenceTargets } from './PreviewReferences';

interface PreviewReceipt { path: string; title: string; }
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
  title: string;
  content: string;
  step: number;
  surfaceOffset: number;
  superseded: boolean;
  screenshot?: PreviewScreenshot;
}
export interface PublishedAnswerPart { kind: string; content: string; key: string; preview?: PublishedPreview; }

export function publishedAnswerParts(messageId: string, steps: AgentStep[], index: number, status: string, latest: string[]): PublishedAnswerPart[] {
  const step = steps[index];
  const final = status === 'complete' && index === steps.length - 1 && !step.tools.length && !step.uiValidation && !step.continuation;
  return previewReferenceParts(step.content, status === 'generating').map((part, position): PublishedAnswerPart => {
    const key = index + ':' + position + ':' + part.kind;
    if (part.kind === 'text') { return { kind: 'text', content: part.content, key: key }; }
    if (!final) { return { kind: 'pending', content: '', key: key }; }
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
  const result: PublishedPreview[] = [];
  let offset = uiParts(step.content, false).filter((part) => part.kind === 'ui').length;
  for (const tool of toolReceipts(step.tools)) {
    if (tool.status !== 'complete' || tool.call.function.name !== 'publish_preview' || !tool.previewContent) { continue; }
    const receipt = previewReceipt(tool.output);
    const referenced = referencePreviewId(tool) !== undefined;
    const id = messageId + ':' + tool.call.id;
    if (!referenced || includeReferenced) { result.push({ id: id, path: receipt.path, title: receipt.title, content: tool.previewContent, step: index,
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
