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
}

export function workspaceRelativePath(path: string, allowRoot: boolean): string {
  if (allowRoot && path === '.') {
    return '';
  }
  if (path.length === 0 || path.length > 1024 || /[\\:\u0000-\u001f\u007f]/.test(path)) {
    throw new Error('path 必须是当前会话工作区内的相对路径。');
  }
  const parts = path.split('/');
  if (parts.length > 16 || parts.some((part: string) =>
    part.length === 0 || part === '.' || part === '..' || part.startsWith('.tinybot-'))) {
    throw new Error('路径不能包含空片段、.、.. 或保留名称 .tinybot-。');
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
      this.definition('write_file', '在当前会话工作区创建或完整覆盖 UTF-8 文本文件，自动创建父目录，最大 64 KiB。', true)
    ];
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const name = call.function.name;
    if (['list_files', 'read_file', 'write_file'].indexOf(name) < 0) {
      throw new Error('不支持的工具：' + name);
    }
    let args: FileArguments;
    try {
      args = JSON.parse(call.function.arguments) as FileArguments;
    } catch (_) {
      throw new Error('工具参数必须是有效的 JSON 对象。');
    }
    if (!args || Array.isArray(args) || typeof args.path !== 'string' ||
      Object.keys(args).some((key: string) => key !== 'path' && (name !== 'write_file' || key !== 'content')) ||
      (name === 'write_file' && typeof args.content !== 'string')) {
      throw new Error('工具参数不符合要求：必须包含 path，写入还需要 content。');
    }
    const path = workspaceRelativePath(args.path, name === 'list_files');
    if (name === 'list_files') {
      return this.files.list(path, cancellation);
    }
    if (name === 'read_file') {
      return this.files.read(path, cancellation);
    }
    return this.files.write(path, args.content as string, cancellation);
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
