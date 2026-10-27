import { AgentStep } from './Agent';
import { previewReferenceTargets } from './PreviewReferences';
import { ToolFailure } from './ToolFailure';

export interface BrowserPreview { previewId: string; title: string; version: string; content: string; viewportWidth?: number; }
export interface PreviewSourceMessage { steps?: AgentStep[]; }

// Resolve only durable receipts belonging to this chat, including its current draft.
export function resolveBrowserPreview(messages: PreviewSourceMessage[], previewId: string): BrowserPreview {
  if (!/^pv_[A-Za-z0-9_-]{1,77}$/.test(previewId)) {
    throw new ToolFailure('INVALID_ARGUMENTS', 'Expected a published previewId.', 'fix_arguments');
  }
  for (const message of messages) {
    const target = previewReferenceTargets(message.steps || []).find((item) => item.previewId === previewId);
    if (target) {
      const receipt = JSON.parse(target.tool.output) as Record<string, string>;
      return { previewId: previewId, title: target.title, version: receipt.version, viewportWidth: target.tool.previewScreenshot?.viewportWidth, content: target.tool.previewContent as string };
    }
  }
  throw new ToolFailure('PREVIEW_NOT_FOUND', 'Preview is not a successful publication in this chat.', 'publish_preview');
}
