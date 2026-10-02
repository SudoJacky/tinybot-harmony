import { t } from '../model/I18n';
import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

export const MAX_FILE_BYTES: number = 64 * 1024;

export interface WorkspaceFiles {
  list(path: string, cancellation: Cancellation): Promise<string>;
  read(path: string, cancellation: Cancellation): Promise<string>;
  write(path: string, content: string, cancellation: Cancellation): Promise<string>;
}

interface FileArguments {
  path: string;
  content?: string;
  oldText?: string;
  newText?: string;
  query?: string;
  startLine?: number;
  endLine?: number;
}

interface ListingEntry { name: string; kind: string; }
interface Listing { entries: ListingEntry[]; truncated: boolean; }
interface TextFile { content: string; }
interface SearchMatch { path: string; line: number; text: string; }

export function replaceUnique(content: string, oldText: string, newText: string): string {
  if (!oldText || content.indexOf(oldText) < 0) { throw new Error(t("原文不存在，请重新读取文件。")); }
  if (content.indexOf(oldText, content.indexOf(oldText) + 1) >= 0) { throw new Error(t("原文匹配多处，请提供更多上下文。")); }
  return content.replace(oldText, () => newText);
}

export function workspaceRelativePath(path: string, allowRoot: boolean): string {
  if (allowRoot && path === '.') {
    return '';
  }
  if (path.length === 0 || path.length > 1024 || /[\\:\u0000-\u001f\u007f]/.test(path)) {
    throw new Error(t("path 必须是当前会话工作区内的相对路径。"));
  }
  const parts = path.split('/');
  if (parts.length > 16 || parts.some((part: string) =>
    part.length === 0 || part === '.' || part === '..' || part.startsWith('.tinybot-'))) {
    throw new Error(t("路径不能包含空片段、.、.. 或保留名称 .tinybot-。"));
  }
  return parts.join('/');
}

export class WorkspaceTools implements AgentTools {
  private files: WorkspaceFiles;

  constructor(files: WorkspaceFiles) {
    this.files = files;
  }

  definitions(): ToolDefinition[] {
    return [
      this.definition('list_files', '列出当前会话工作区内一个目录的直接子项；path 为 . 表示工作区根目录，最多返回 200 项。', false),
      this.definition('read_file', '读取当前会话工作区中的 UTF-8 文本文件，最大 64 KiB。', false),
      this.definition('write_file', '在当前会话工作区创建或完整覆盖 UTF-8 文本文件，自动创建父目录，最大 64 KiB。', true),
      this.extraDefinition('search_file_content', '递归搜索工作区 UTF-8 文本中的字面关键词，返回路径、行号和片段。最多检查 200 个文件、返回 100 个匹配；truncated 表示结果不完整。',
        { 'path': { type: 'string', description: '目录相对路径，根目录使用 .' }, 'query': { type: 'string', description: '非空字面关键词，区分大小写' } }, ['path', 'query']),
      this.extraDefinition('read_file_lines', '按行读取不超过 64 KiB 的文本，行号从 1 开始，最多 200 行。',
        { 'path': { type: 'string', description: '文件相对路径' }, 'startLine': { type: 'integer', description: '开始行' }, 'endLine': { type: 'integer', description: '结束行（含）' } }, ['path', 'startLine', 'endLine']),
      this.extraDefinition('edit_file', '精准替换唯一匹配的原文。必须先读取文件；匹配不存在或多处时拒绝修改。保留修改前基线供用户审阅。',
        { 'path': { type: 'string', description: '文件相对路径' }, 'oldText': { type: 'string', description: '唯一匹配的非空原文' }, 'newText': { type: 'string', description: '替换文字，可以为空' } }, ['path', 'oldText', 'newText'])
    ];
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const name = call.function.name;
    if (['list_files', 'read_file', 'write_file', 'search_file_content', 'read_file_lines', 'edit_file'].indexOf(name) < 0) {
      throw new Error(t("不支持的工具：") + name);
    }
    let args: FileArguments;
    try {
      args = JSON.parse(call.function.arguments) as FileArguments;
    } catch (_) {
      throw new Error(t("工具参数必须是有效的 JSON 对象。"));
    }
    if (!args || Array.isArray(args) || typeof args.path !== 'string' ||
      Object.keys(args).some((key: string) => !['path', 'content', 'oldText', 'newText', 'query', 'startLine', 'endLine'].includes(key)) ||
      (name === 'write_file' && typeof args.content !== 'string')) {
      throw new Error(t("工具参数不符合要求：必须包含 path，写入还需要 content。"));
    }
    const path = workspaceRelativePath(args.path, name === 'list_files' || name === 'search_file_content');
    if (name === 'search_file_content') {
      if (typeof args.query !== 'string' || !args.query || args.query.length > 1000) { throw new Error(t("搜索关键词需为 1–1000 字符。")); }
      return this.search(path, args.query, cancellation);
    }
    if (name === 'edit_file' || name === 'read_file_lines') {
      const content = (JSON.parse(await this.files.read(path, cancellation)) as TextFile).content;
      if (name === 'edit_file') {
        if (typeof args.oldText !== 'string' || typeof args.newText !== 'string') { throw new Error(t("编辑需要 oldText 和 newText。")); }
        return this.files.write(path, replaceUnique(content, args.oldText, args.newText), cancellation);
      }
      const start = args.startLine || 0; const end = args.endLine || 0;
      if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start || end - start >= 200) { throw new Error(t("行范围无效，最多 200 行。")); }
      const lines = content.split('\n');
      return JSON.stringify({ path: path, startLine: start, totalLines: lines.length, content: lines.slice(start - 1, end).join('\n') });
    }
    if (name === 'list_files') {
      return this.files.list(path, cancellation);
    }
    if (name === 'read_file') {
      return this.files.read(path, cancellation);
    }
    return this.files.write(path, args.content as string, cancellation);
  }

  private extraDefinition(name: string, description: string, properties: Record<string, ToolProperty>, required: string[]): ToolDefinition {
    return { type: 'function', function: { name: name, description: description, parameters: {
      type: 'object', properties: properties, required: required, additionalProperties: false } } };
  }

  private async search(path: string, query: string, cancellation: Cancellation): Promise<string> {
    const pending: string[] = [path]; const matches: SearchMatch[] = []; const skipped: string[] = [];
    let checked = 0; let directories = 0; let truncated = false;
    while (pending.length && checked < 200 && matches.length < 100 && directories < 100) {
      cancellation.check(); const directory = pending.shift() || ''; directories++;
      const listing = JSON.parse(await this.files.list(directory, cancellation)) as Listing;
      truncated = truncated || listing.truncated;
      for (const entry of listing.entries) {
        if (checked >= 200 || matches.length >= 100) { truncated = true; break; }
        if (entry.name.startsWith('.')) { continue; }
        const file = (directory ? directory + '/' : '') + entry.name;
        if (entry.kind === 'directory') { pending.push(file); continue; }
        if (entry.kind !== 'file') { continue; }
        checked++;
        let content = '';
        try { content = (JSON.parse(await this.files.read(file, cancellation)) as TextFile).content; }
        catch (_) { cancellation.check(); skipped.push(file); continue; }
        const lines = content.split('\n');
        for (let i = 0; i < lines.length; i++) {
          if (lines[i].includes(query)) {
            if (matches.length >= 100) { truncated = true; break; }
            matches.push({ path: file, line: i + 1, text: lines[i].slice(0, 300) });
          }
        }
      }
    }
    return JSON.stringify({ matches: matches, skipped: skipped, checkedFiles: checked, truncated: truncated || pending.length > 0 });
  }

  private definition(name: string, description: string, write: boolean): ToolDefinition {
    const properties: Record<string, ToolProperty> = {
      'path': { type: 'string', description: '相对于当前会话工作区的路径，不能越过工作区。' }
    };
    if (write) {
      properties['content'] = { type: 'string', description: '要写入的完整 UTF-8 文本。' };
    }
    return { type: 'function', function: { name: name, description: description,
      parameters: { type: 'object', properties: properties, required: write ? ['path', 'content'] : ['path'],
        additionalProperties: false } } };
  }
}
