import { ToolCall, ToolDefinition, PreviewScreenshot } from '../model/Agent';
import { UiRecord, UiCompiler, validateUiAnswer } from '../model/InteractiveUi';
import { WebUiSpec } from '../model/WebUi';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { WorkspaceFiles } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';
import { UiDiagnosticError, repairGuidance } from '../model/UiRepair';

interface PreviewArguments { path: string; title?: string; }
interface PreviewImageInfo { width: number; height: number; viewportWidth: number; }
interface PreviewReceipt { published: boolean; path: string; title: string; nodes: number; screenshot?: PreviewImageInfo; }

// Resolve/read once, validate that exact snapshot, then attach it to the durable receipt.
export class PreviewTools implements AgentTools {
  private files: WorkspaceFiles;
  private preflight: (content: string, cancellation: Cancellation) => Promise<void>;
  private capture?: (content: string, cancellation: Cancellation) => Promise<PreviewScreenshot>;
  constructor(files: WorkspaceFiles, preflight: (content: string, cancellation: Cancellation) => Promise<void>,
    capture?: (content: string, cancellation: Cancellation) => Promise<PreviewScreenshot>) {
    this.files = files; this.preflight = preflight; this.capture = capture;
  }
  definitions(): ToolDefinition[] {
    return [{ type: 'function', executionMode: 'sequential', promptSnippet: '发布文件预览',
      promptGuidelines: ['SVG、HTML 或 tinybot-ui JSONL 文件写好后调用 publish_preview 按路径发布；客户端负责序列化、校验和显示，并返回设备渲染截图供视觉检查。检查留白、裁切和可读性后再结束；有问题时修改源文件并重新发布。成功后不要在回答里重复抄写预览 JSON。文件下载另用 present_files。'],
      function: { name: 'publish_preview', description: '从当前工作区的 .svg、.html 或 .jsonl 文件发布一个预览。SVG/HTML 自动包装为隔离 Web；JSONL 使用 tinybot-ui 记录（无代码围栏）。发布前运行客户端校验和 Web 启动检查，成功后保存不可变快照。HTML 必须自包含，无网络或本地资源依赖；脚本通过现有 Web 沙箱执行。',
        parameters: { type: 'object', properties: {
          'path': { type: 'string', description: '现有工作区文件相对路径，.svg/.html/.jsonl' },
          'title': { type: 'string', description: 'SVG/HTML 预览标题，最多 160 字符，默认文件名；JSONL 使用 begin.title' }
        }, required: ['path'], additionalProperties: false } } }];
  }
  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    const args = parseToolArguments(call.function.arguments) as PreviewArguments;
    if (call.function.name !== 'publish_preview' || !args || Array.isArray(args) || typeof args.path !== 'string' ||
      Object.keys(args).some((key) => !['path', 'title'].includes(key)) ||
      (args.title !== undefined && (typeof args.title !== 'string' || !args.title.trim() || args.title.length > 160))) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected path and an optional non-empty title of at most 160 characters.', 'fix_arguments');
    }
    if (!context) { throw new Error('Preview publication requires a durable tool invocation context'); }
    const path = workspaceRelativePath(args.path, false);
    if (!/\.(svg|html|jsonl)$/i.test(path)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Preview requires a .svg, .html or .jsonl file.', 'fix_arguments'); }
    const snapshot = await this.files.read(path, cancellation);
    const source = snapshot.content;
    cancellation.check();
    let wire = source;
    let phase = 'INVALID_FIELD';
    try {
      if (!/\.jsonl$/i.test(path)) {
        const title = args.title || path.split('/').pop()?.slice(0, 160) || 'Preview';
        const spec: WebUiSpec = { version: 1, html: source,
          css: 'html,body{margin:0;width:100%;min-height:100%;}svg{display:block;max-width:100%;height:auto;margin:auto;}',
          js: '', library: 'none', height: 400, autoHeight: true };
        const records: UiRecord[] = [{ op: 'begin', version: 1, title: title, state: {} },
          { op: 'node', node: { id: 'preview', kind: 'web', data: JSON.stringify(spec) } }, { op: 'end' }];
        wire = records.map((record) => JSON.stringify(record)).join('\n');
      }
      // Compile raw JSONL before wrapping: a fence in a malformed file cannot hide records.
      const document = new UiCompiler().update(wire, true);
      const content = '```tinybot-ui\n' + wire + '\n```';
      validateUiAnswer(content);
      phase = 'WEB_STARTUP_FAILED';
      await this.preflight(content, cancellation);
      cancellation.check();
      phase = 'SCREENSHOT_FAILED';
      const screenshot = this.capture ? await this.capture(content, cancellation) : undefined;
      cancellation.check();
      context.execution.previewContent = content;
      context.execution.previewScreenshot = screenshot;
      const receipt: PreviewReceipt = { published: true, path: path, title: document.title, nodes: document.nodes.length,
        screenshot: screenshot ? { width: screenshot.width, height: screenshot.height, viewportWidth: screenshot.viewportWidth } : undefined };
      return JSON.stringify(receipt);
    } catch (error) {
      cancellation.check();
      const diagnostic = error instanceof UiDiagnosticError ? error : new UiDiagnosticError(phase, (error as Error).message);
      throw new ToolFailure('PREVIEW_INVALID', 'Preview file ' + path + ': ' + (error as Error).message,
        'fix_preview_file', { path: path, version: snapshot.version, category: diagnostic.code,
          location: diagnostic.location, locationScope: /\.jsonl$/i.test(path) ? 'jsonl_source' : 'generated_wrapper',
          excerpt: diagnostic.excerpt, repair: repairGuidance(diagnostic.code, path, args.title) });
    }
  }
}
