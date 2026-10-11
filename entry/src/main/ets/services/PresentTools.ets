import { ToolCall, ToolDefinition } from '../model/Agent';
import { PresentedFile } from '../model/Deliverables';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { workspaceRelativePath } from './WorkspaceTools';

interface PresentArguments { files: PresentedFile[]; }

// The successful tool receipt is the delivery record; no second mutable file list.
export class PresentTools implements AgentTools {
  private checkFile: (path: string) => Promise<string>;
  constructor(checkFile: (path: string) => Promise<string>) { this.checkFile = checkFile; }
  definitions(): ToolDefinition[] {
    return [{ type: 'function', executionMode: 'sequential', promptSnippet: '交付工作区文件',
      promptGuidelines: ['完成文件后用 present_files 交付，成功回执才会显示文件卡片。只交付当前工作区真实存在的文件。'],
      function: { name: 'present_files', description: '向用户交付 1–8 个已存在的工作区文件，显示可打开、分享和导出的文件卡片。不会创建文件。',
        parameters: { type: 'object', properties: { 'files': { type: 'array', description: '交付文件', items: {
          type: 'object', description: '文件', properties: { 'path': { type: 'string', description: '当前工作区相对路径' },
            'description': { type: 'string', description: '简短说明，最多 300 字符' } }, required: ['path'], additionalProperties: false } } },
          required: ['files'], additionalProperties: false } } }];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const args = JSON.parse(call.function.arguments) as PresentArguments;
    if (call.function.name !== 'present_files' || !args || Array.isArray(args) || Object.keys(args).some((key) => key !== 'files') ||
      !Array.isArray(args.files) || args.files.length < 1 || args.files.length > 8) { throw new Error('Expected 1–8 workspace files.'); }
    const files: PresentedFile[] = []; const seen = new Set<string>();
    for (const file of args.files) {
      if (!file || typeof file.path !== 'string' || Object.keys(file).some((key) => !['path', 'description'].includes(key)) ||
        (file.description !== undefined && (typeof file.description !== 'string' || file.description.length > 300))) { throw new Error('Invalid file delivery.'); }
      const path = workspaceRelativePath(file.path, false);
      if (seen.has(path)) { throw new Error('Duplicate delivered file.'); }
      await this.checkFile(path); cancellation.check(); seen.add(path);
      files.push({ path: path, description: file.description });
    }
    return JSON.stringify({ files: files });
  }
}
