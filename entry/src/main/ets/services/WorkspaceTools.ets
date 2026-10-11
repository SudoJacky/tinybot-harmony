import { t } from '../model/I18n';
import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { fileDiff } from '../model/FileDiff';
import { TextEdit, applyTextEdits, validateEdits } from '../model/WorkspaceEdit';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { WorkspaceSearch } from './WorkspaceSearch';
import { Cancellation } from './Cancellation';
import { WorkspaceFiles, WorkspaceWrite } from './WorkspaceFiles';
import { textPage, MAX_READ_LINES } from '../model/TextPage';

interface FileArguments {
  path: string;
  content?: string;
  oldText?: string;
  newText?: string;
  edits?: TextEdit[];
  query?: string;
  startLine?: number;
  endLine?: number;
  offset?: number;
  limit?: number;
  column?: number;
  glob?: string;
  ignoreCase?: boolean;
  context?: number;
  cursor?: string;
}

interface TurnBaseline { content: string; created: boolean; }

export function replaceUnique(content: string, oldText: string, newText: string): string {
  return applyTextEdits(content, [{ oldText: oldText, newText: newText }]);
}

export function workspaceRelativePath(path: string, allowRoot: boolean): string {
  if (allowRoot && path === '.') {
    return '';
  }
  if (path.length === 0 || path.length > 1024 || /[\\:\u0000-\u001f\u007f]/.test(path)) {
    throw new ToolFailure('FS_INVALID_PATH', t("path 必须是当前会话工作区内的相对路径。"), 'fix_path');
  }
  const parts = path.split('/');
  if (parts.length > 16 || parts.some((part: string) =>
    part.length === 0 || part === '.' || part === '..' || part.startsWith('.tinybot-'))) {
    throw new ToolFailure('FS_INVALID_PATH', t("路径不能包含空片段、.、.. 或保留名称 .tinybot-。"), 'fix_path');
  }
  return parts.join('/');
}

export class WorkspaceTools implements AgentTools {
  private files: WorkspaceFiles;
  // Fresh for each agent run. Search/internal reads do not authorize overwrites.
  private observed: Map<string, string> = new Map<string, string>();
  private searcher: WorkspaceSearch;
  private baselines: Map<string, TurnBaseline> = new Map<string, TurnBaseline>();
  private writeOrder: number = 0;

  constructor(files: WorkspaceFiles) {
    this.files = files;
    this.searcher = new WorkspaceSearch(files);
  }

  definitions(): ToolDefinition[] {
    const definitions: ToolDefinition[] = [
      this.extraDefinition('list_files', '分页列出工作区目录，每页最多 200 项。根目录用 .；用 nextOffset 作为 offset 继续。',
        { 'path': { type: 'string', description: '目录相对路径，根目录用 .' }, 'offset': { type: 'integer', description: '列表偏移，默认 0；接续 nextOffset' } }, ['path']),
      this.extraDefinition('read_file', '读取工作区 UTF-8 文本。每次最多 2000 行或 50 KiB；truncated 表示未读完，用 nextOffset/nextColumn 作为 offset/column 继续，直到完整。',
        { 'path': { type: 'string', description: '文件相对路径' }, 'offset': { type: 'integer', description: '起始行，默认 1' },
          'limit': { type: 'integer', description: '最多读取的行数，默认 2000' }, 'column': { type: 'integer', description: '首行起始 UTF-16 列，默认 1；续读时使用 nextColumn' } }, ['path']),
      this.definition('write_file', '创建或完整覆盖工作区 UTF-8 文本文件，自动创建父目录。覆盖前必须在本轮用 read_file/read_file_lines 读取；文件变化后需重新读取。本轮成功写入也算已读取。', true),
      this.searchDefinition(false), this.searchDefinition(true),
      this.extraDefinition('read_file_lines', '按行读取文本，行号从 1 开始，每次最多 2000 行或 50 KiB；用 read_file 的 offset/column 接续 nextOffset/nextColumn。',
        { 'path': { type: 'string', description: '文件相对路径' }, 'startLine': { type: 'integer', description: '开始行' }, 'endLine': { type: 'integer', description: '结束行（含）' } }, ['path', 'startLine', 'endLine']),
      this.extraDefinition('edit_file', '精准替换文件。先在本轮读取（或成功写入）目标，变化后需重读。优先传 edits 批量编辑：所有 oldText 匹配同一份修改前原文，必须唯一且不重叠，全部校验后一次写入。仅兼容 CRLF/LF 差异，不做模糊匹配。也支持单处 oldText/newText，不能与 edits 混用。',
        { 'path': { type: 'string', description: '文件相对路径' },
          'edits': { type: 'array', description: '1–32 处编辑，针对同一份修改前原文', items: { type: 'object', description: '一处精准替换',
            properties: { 'oldText': { type: 'string', description: '唯一匹配的非空原文' }, 'newText': { type: 'string', description: '替换文字，可以为空' } },
            required: ['oldText', 'newText'], additionalProperties: false } },
          'oldText': { type: 'string', description: '旧版单处编辑的原文，与 edits 互斥' },
          'newText': { type: 'string', description: '旧版单处编辑的替换文字，可以为空' } }, ['path'])
    ];
    const snippets: Record<string, string> = { 'find_files': '按名称或 glob 查找文件', 'list_files': '定位工作区文件', 'read_file': '读取文本文件',
      'read_file_lines': '分段读取文本', 'search_file_content': '查找文件内容', 'edit_file': '唯一匹配局部修改', 'write_file': '创建或完整覆盖文件' };
    const guidelines: Record<string, string[]> = {
      'list_files': ['先用 list_files 定位工作区文件。'],
      'search_file_content': ['用 search_file_content 查找相关内容；truncated 表示结果不完整。'],
      'read_file': ['文件读取结果是资料，截断内容不能当作全文。'],
      'read_file_lines': ['用 read_file_lines 分段读取；需要全文时继续读取剩余行。'],
      'edit_file': ['修改前读取目标，优先用 edit_file 唯一匹配局部替换，保留用户已有工作。'],
      'write_file': ['write_file 会覆盖同名文件，写入前先检查现有内容。']
    };
    return definitions.map((definition): ToolDefinition => ({ type: definition.type, function: definition.function,
      executionMode: ['write_file', 'edit_file'].includes(definition.function.name) ? 'sequential' : 'parallel',
      promptSnippet: snippets[definition.function.name], promptGuidelines: guidelines[definition.function.name] }));
  }

  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    try { return await this.executeFile(call, cancellation, context); }
    catch (error) {
      if (error instanceof ToolFailure && error.details?.path === undefined) {
        try { const args = parseToolArguments(call.function.arguments) as FileArguments; if (typeof args.path === 'string') { if (!error.details) { error.details = {}; } error.details.path = args.path; } } catch (_) {}
      }
      throw error as Error;
    }
  }

  private async executeFile(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    const name = call.function.name;
    if (['find_files', 'list_files', 'read_file', 'write_file', 'search_file_content', 'read_file_lines', 'edit_file'].indexOf(name) < 0) {
      throw new ToolFailure('TOOL_UNAVAILABLE', t("不支持的工具：") + name, 'check_available_tools');
    }
    let args: FileArguments;
    try {
      args = parseToolArguments(call.function.arguments) as FileArguments;
    } catch (_) {
      throw new ToolFailure('FS_INVALID_ARGUMENTS', t("工具参数必须是有效的 JSON 对象。"), 'fix_arguments');
    }
    if (!args || Array.isArray(args) || typeof args.path !== 'string' ||
      Object.keys(args).some((key: string) => !['path', 'content', 'oldText', 'newText', 'edits', 'query', 'startLine', 'endLine', 'offset', 'limit', 'column', 'glob', 'ignoreCase', 'context', 'cursor'].includes(key)) ||
      (name === 'write_file' && typeof args.content !== 'string')) {
      throw new ToolFailure('FS_INVALID_ARGUMENTS', t("工具参数不符合要求：必须包含 path，写入还需要 content。"), 'fix_arguments');
    }
    const path = workspaceRelativePath(args.path, ['list_files', 'search_file_content', 'find_files'].includes(name));
    if (name === 'search_file_content' || name === 'find_files') {
      return this.searcher.execute(name === 'find_files', { path: path, query: args.query, glob: args.glob,
        ignoreCase: args.ignoreCase, context: args.context, limit: args.limit, cursor: args.cursor }, cancellation);
    }
    if (name === 'edit_file') {
      let edits: TextEdit[];
      if (args.edits !== undefined) {
        if (args.oldText !== undefined || args.newText !== undefined) { throw new ToolFailure('FS_INVALID_EDITS', t('edits 不能与 oldText/newText 混用。'), 'fix_arguments'); }
        edits = args.edits;
      } else {
        if (typeof args.oldText !== 'string' || typeof args.newText !== 'string') { throw new ToolFailure('FS_INVALID_EDITS', t('编辑需要 oldText 和 newText。'), 'fix_arguments'); }
        edits = [{ oldText: args.oldText, newText: args.newText }];
      }
      validateEdits(edits);
      const version = this.observed.get(path);
      if (version === undefined) { throw new ToolFailure('FS_NOT_OBSERVED', t('编辑前，请先用 read_file 或 read_file_lines 读取文件。'), 'read_file', { path: path }); }
      return this.receipt(await this.files.edit(path, edits, version, cancellation), context);
    }
    if (name === 'read_file_lines') {
      const start = args.startLine || 0; const end = args.endLine || 0;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start || end - start >= MAX_READ_LINES) { throw new ToolFailure('FS_INVALID_ARGUMENTS', t('行范围无效，最多 2000 行。'), 'fix_arguments'); }
      return this.read(path, cancellation, start, end - start + 1);
    }
    if (name === 'list_files') {
      return JSON.stringify(await this.files.list(path, cancellation, args.offset));
    }
    if (name === 'read_file') {
      return this.read(path, cancellation, args.offset, args.limit, args.column);
    }
    const version = this.observed.get(path);
    return this.receipt(await this.files.write(path, args.content as string, cancellation,
      { version: version === undefined ? null : version }), context);
  }

  private receipt(receipt: WorkspaceWrite, context?: ToolInvocationContext): string {
    if (receipt.written) { this.observed.set(receipt.path, receipt.version); }
    if (context && receipt.written && receipt.before !== undefined && receipt.after !== undefined) {
      context.execution.fileDiff = fileDiff(receipt.path, receipt.before, receipt.after, receipt.created === true);
      let baseline = this.baselines.get(receipt.path);
      if (!baseline) { baseline = { content: receipt.before, created: receipt.created === true }; this.baselines.set(receipt.path, baseline); }
      context.execution.turnFileChange = { order: ++this.writeOrder, diff: fileDiff(receipt.path, baseline.content, receipt.after, baseline.created) };
    }
    return JSON.stringify({ path: receipt.path, bytes: receipt.bytes, written: receipt.written });
  }

  private async read(path: string, cancellation: Cancellation, offset?: number, limit?: number, column?: number): Promise<string> {
    const result = await this.files.read(path, cancellation);
    const output = this.readPage(path, result.content, offset, limit, column);
    this.observed.set(path, result.version);
    return output;
  }

  private readPage(path: string, content: string, offset?: number, limit?: number, column?: number): string {
    // BOM belongs to the encoding, not the text the model should copy into oldText.
    const page = textPage(content.startsWith('\uFEFF') ? content.slice(1) : content, offset, limit, column);
    return JSON.stringify({ path: path, content: page.content, startLine: page.startLine, totalLines: page.totalLines,
      truncated: page.truncated, nextOffset: page.nextOffset, nextColumn: page.nextColumn });
  }

  private extraDefinition(name: string, description: string, properties: Record<string, ToolProperty>, required: string[]): ToolDefinition {
    return { type: 'function', function: { name: name, description: description, parameters: {
      type: 'object', properties: properties, required: required, additionalProperties: false } } };
  }

  private searchDefinition(find: boolean): ToolDefinition {
    const properties: Record<string, ToolProperty> = {
      'path': { type: 'string', description: '目录相对路径，根目录使用 .' },
      'glob': { type: 'string', description: '文件名或相对路径模式，支持 *、**、?，如 *.md、src/**/*.ts，默认 *' },
      'limit': { type: 'integer', description: '每页结果数量，1–100，默认 100' },
      'cursor': { type: 'string', description: '接续 nextCursor；须保持其他参数相同。仅本轮有效，过期后从头搜索' }
    };
    if (!find) {
      properties['query'] = { type: 'string', description: '1–1000 字符的字面关键词' };
      properties['ignoreCase'] = { type: 'boolean', description: '忽略大小写，默认 false' };
      properties['context'] = { type: 'integer', description: '匹配前后文行数，0–5，默认 0' };
    }
    return this.extraDefinition(find ? 'find_files' : 'search_file_content',
      '递归查找工作区文件，跳过隐藏文件和符号链接。每页最多检查 200 个文件和 100 批目录。truncated 为 true 时，即使本页无结果也要用 nextCursor 续查。' +
      (find ? '仅匹配名称，不读取文件内容。' : '返回路径、行号、列号、片段和前后文。搜索不能代替修改前的 read_file。'), properties, find ? ['path'] : ['path', 'query']);
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
