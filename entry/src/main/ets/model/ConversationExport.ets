import { AppData, ThreadData, MessageData } from './Conversation';
import { ToolExecution } from './Agent';
import { Attachment } from './Productivity';
import { MarkdownBlock, markdownBlocks } from './Markdown';
import { t } from './I18n';
import { parseDataView } from './RichArtifacts';
import { ProviderProfile } from './ProviderProfiles';
import { latestPreviewIds, PreviewMessage } from './PublishedPreview';

export interface ConversationSection {
  kind: string;
  text: string;
  user: boolean;
  block?: MarkdownBlock;
  attachment?: Attachment;
  provider?: string;
  providerPreset?: string;
  model?: string;
  bubbleStart?: boolean;
  bubbleEnd?: boolean;
  imageRatio?: number;
}
const SECTION_CHARS = 2400;
function addText(sections: ConversationSection[], content: string, user: boolean): void {
  for (const block of markdownBlocks(content)) {
    if (block.kind === 'table') {
      // One row per capture keeps large tables complete without horizontal clipping.
      for (let index = 0; index < block.rows.length; index++) {
        const row = block.rows[index];
        if (row.length > 4 || row.some((cell: string) => cell.length > 240)) {
          // Wide tables become labelled records, preserving every cell at a readable size.
          row.forEach((cell: string, column: number) => {
            addText(sections, (index > 0 ? (block.rows[0][column] || String(column + 1)) + ': ' : '') + cell, user);
          });
        } else {
          sections.push({ kind: 'table', text: row.join('\n'), user: user,
            block: { kind: 'table', text: '', level: 0, rows: [row] } });
        }
      }
    } else if (block.kind === 'image' || block.kind === 'rule') {
      sections.push({ kind: block.kind, text: block.text, user: user, block: block });
    } else {
      // Split very long paragraphs/code before snapshotting, keeping every character.
      let offset = 0;
      do {
        let end = Math.min(block.text.length, offset + SECTION_CHARS);
        let lineEnd = offset;
        for (let line = 0; line < 60; line++) {
          lineEnd = block.text.indexOf('\n', lineEnd);
          if (lineEnd === -1 || lineEnd >= end) { break; }
          lineEnd++;
          if (line === 59) { end = lineEnd; }
        }
        if (end < block.text.length && /[\uD800-\uDBFF]/.test(block.text.charAt(end - 1))) { end--; }
        const value = block.text.slice(offset, end);
        sections.push({ kind: block.kind, text: value, user: user,
          block: { kind: block.kind, text: value, level: block.level, rows: block.rows } });
        offset = end;
      } while (offset < block.text.length);
    }
  }
}
function addAttachments(sections: ConversationSection[], attachments: Attachment[], user: boolean): void {
  for (const attachment of attachments) {
    sections.push({ kind: attachment.mime.startsWith('image/') ? 'attachment-image' : 'attachment',
      text: attachment.name, user: user, attachment: attachment });
  }
}
function addMessage(sections: ConversationSection[], message: MessageData, profiles: ProviderProfile[], latest: string[]): void {
  const user = message.role === 'user';
  const profile = profiles.find((item) => item.id === message.modelRef?.providerId);
  const role: ConversationSection = { kind: 'role', text: user ? t('用户') : 'Tinybot', user: user,
    provider: user ? '' : profile?.name || message.modelRef?.providerId || '',
    providerPreset: user ? '' : profile?.presetId || '', model: user ? '' : message.modelRef?.modelId || '' };
  sections.push(role);
  for (const reference of message.references || []) { addText(sections, reference.title, user); }
  addAttachments(sections, message.attachments || [], user);
  if (!user && message.steps?.length) {
    for (const step of message.steps) {
      if (step.steering) {
        sections.push({ kind: 'role', text: t('用户'), user: true });
        addText(sections, step.steering.text, true); addAttachments(sections, step.steering.attachments || [], true);
        sections.push({ kind: 'role', text: role.text, user: false, provider: role.provider,
          providerPreset: role.providerPreset, model: role.model });
      }
      if (!step.requestError) { addText(sections, step.content, false); }
      for (const tool of step.tools) {
        if (tool.previewScreenshot && (tool.call.function.name !== 'publish_preview' || latest.includes(message.id + ':' + tool.call.id))) {
          sections.push({ kind: 'attachment-image', text: tool.previewScreenshot.image.name, user: false,
            attachment: tool.previewScreenshot.image, imageRatio: tool.previewScreenshot.height / tool.previewScreenshot.width });
        }
        if (tool.status === 'complete' && tool.call.function.name === 'publish_data_view') {
          const view = parseDataView(tool.output);
          if (view.kind === 'table') {
            sections.push({ kind: 'heading', text: view.title, user: false });
            for (const row of view.rows) {
              row.values.forEach((value, column: number) => addText(sections, view.columns[column].label + ': ' + String(value), false));
            }
            addText(sections, view.source, false);
          } else { sections.push({ kind: 'data-view', text: tool.output, user: false }); }
        }
      }
    }
  } else { addText(sections, message.content, user); }
  if (message.error) { sections.push({ kind: 'error', text: message.error, user: user }); }
}
export function conversationSections(thread: ThreadData, profiles: ProviderProfile[] = []): ConversationSection[] {
  const result: ConversationSection[] = [{ kind: 'title', text: thread.title, user: false }];
  const latest = latestPreviewIds(thread.messages.map((message): PreviewMessage => ({ id: message.id, steps: message.steps || [] })));
  for (const message of thread.messages) { addMessage(result, message, profiles, latest); }
  result.push({ kind: 'footer', text: 'Tinybot · ' + t('含 AI 生成内容') + '\n' + t('AI生成内容可能有误，请仔细鉴别。'), user: false });
  result.forEach((section: ConversationSection, index: number) => {
    if (section.user) {
      section.bubbleStart = section.kind === 'role';
      section.bubbleEnd = !result[index + 1]?.user || result[index + 1]?.kind === 'role';
    }
  });
  return result;
}

function normalized(path: string): string { return path.replace(/\\/g, '/').replace(/^(\.\/)+/, ''); }
function toolModified(tools: ToolExecution[], path: string): boolean {
  for (const tool of tools) {
    if (tool.status === 'complete' && ['write_file', 'edit_file'].includes(tool.call.function.name)) {
      const args = JSON.parse(tool.call.function.arguments) as Record<string, string>;
      if (typeof args.path === 'string' && normalized(args.path) === path) { return true; }
    }
    if (toolModified(tool.children || [], path)) { return true; }
  }
  return false;
}
// Merely importing or exporting a user document is not evidence of AI authorship.
export function aiAssistedFile(data: AppData, workspaceId: string, path: string): boolean {
  const target = normalized(path);
  return data.threads.some((thread: ThreadData): boolean => {
    const workspace = thread.projectId ? data.projects?.find((project) => project.id === thread.projectId)?.workspaceId : thread.id;
    if (workspace !== workspaceId) { return false; }
    return !!thread.compaction?.fileOperations?.modifiedFiles.some((file: string) => normalized(file) === target) ||
      thread.messages.some((message) => (message.steps || []).some((step) => toolModified(step.tools, target)));
  });
}
