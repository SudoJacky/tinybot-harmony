import { AgentStep, PreviewScreenshot } from './Agent';
import { uiParts } from './InteractiveUi';

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

// Only successful publications replace an earlier revision. Keep distinct files independent.
export function latestPreviewIds(messages: PreviewMessage[]): string[] {
  const latest = new Map<string, string>();
  for (const message of messages) {
    for (const step of message.steps) {
      for (const tool of step.tools) {
        if (tool.status === 'complete' && tool.call.function.name === 'publish_preview' && tool.previewContent) {
          const receipt = previewReceipt(tool.output);
          latest.set(receipt.path, message.id + ':' + tool.call.id);
        }
      }
    }
  }
  return Array.from(latest.values());
}

export function publishedPreviews(messageId: string, steps: AgentStep[], latest: string[]): PublishedPreview[] {
  const result: PublishedPreview[] = [];
  for (let index = 0; index < steps.length; index++) {
    result.push(...stepPreviews(messageId, steps[index], index, latest));
  }
  return result;
}

export function stepPreviews(messageId: string, step: AgentStep, index: number, latest: string[]): PublishedPreview[] {
  const result: PublishedPreview[] = [];
  let offset = uiParts(step.content, false).filter((part) => part.kind === 'ui').length;
  for (const tool of step.tools) {
    if (tool.status !== 'complete' || tool.call.function.name !== 'publish_preview' || !tool.previewContent) { continue; }
    const receipt = previewReceipt(tool.output);
    const id = messageId + ':' + tool.call.id;
    result.push({ id: id, path: receipt.path, title: receipt.title, content: tool.previewContent, step: index,
      surfaceOffset: offset, superseded: !latest.includes(id), screenshot: tool.previewScreenshot });
    // Preserve the original keys in stepDisplayContent, including multi-surface JSONL files.
    offset += uiParts(tool.previewContent, false).filter((part) => part.kind === 'ui').length;
  }
  return result;
}

// Presentation only. Model history uses step.content and the compact tool receipt.
export function stepDisplayContent(step: AgentStep): string {
  return [step.content].concat(step.tools.filter((tool) => tool.status === 'complete' &&
    tool.call.function.name === 'publish_preview' && !!tool.previewContent).map((tool) => tool.previewContent as string))
    .filter((content) => content.length > 0).join('\n\n');
}
