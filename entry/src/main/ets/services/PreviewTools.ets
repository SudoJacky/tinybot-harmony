import { ToolCall, ToolDefinition, PreviewScreenshot } from '../model/Agent';
import { UiRecord, UiCompiler, validateUiAnswer } from '../model/InteractiveUi';
import { WebUiSpec } from '../model/WebUi';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { WorkspaceFiles } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';
import { UiDiagnosticError, repairGuidance } from '../model/UiRepair';

interface PreviewArguments { path: string; title?: string; library?: string; height?: number; }
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
      promptGuidelines: ['将普通 JS、HTML 或 SVG 写入工作区，再调用 publish_preview 嵌入聊天。Three.js 使用 .js 文件和 library: "three"；不要编写 JSONL。客户端负责包装、启动检查和截图。检查留白、裁切和可读性后再结束；有问题时修改源文件并按原参数重新发布。此工具不打开独立 browser 会话。文件下载另用 present_files。'],
      function: { name: 'publish_preview', description: '发布工作区 .js、.html 或 .svg 文件到聊天内的隔离 Web 卡片。JS 在空白页面中执行，可操作 document.body，支持 await；library="three" 预加载 THREE 和独立 OrbitControls。无 imports、网络、本地文件或存储访问。发布前检查启动并截图，成功后保存不可变快照。JSONL 不再支持。',
        parameters: { type: 'object', properties: {
          'path': { type: 'string', description: '现有工作区文件相对路径，.js/.html/.svg' },
          'title': { type: 'string', description: '预览标题，最多 160 字符，默认文件名' },
          'library': { type: 'string', enum: ['none', 'three'], description: '预加载的内置库，默认 none；three 提供 THREE 和 OrbitControls' },
          'height': { type: 'number', description: '固定卡片内容高度，200–800vp。JS 默认 400；HTML/SVG 默认自适应' }
        }, required: ['path'], additionalProperties: false } } }];
  }
  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    const args = parseToolArguments(call.function.arguments) as PreviewArguments;
    if (call.function.name !== 'publish_preview' || !args || Array.isArray(args) || typeof args.path !== 'string' ||
      Object.keys(args).some((key) => !['path', 'title', 'library', 'height'].includes(key)) ||
      (args.title !== undefined && (typeof args.title !== 'string' || !args.title.trim() || args.title.length > 160)) ||
      (args.library !== undefined && !['none', 'three'].includes(args.library)) ||
      (args.height !== undefined && (typeof args.height !== 'number' || !Number.isFinite(args.height) || args.height < 200 || args.height > 800))) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected path, optional title (1–160 characters), library (none or three), and height (200–800).', 'fix_arguments');
    }
    if (!context) { throw new Error('Preview publication requires a durable tool invocation context'); }
    const path = workspaceRelativePath(args.path, false);
    if (/\.jsonl$/i.test(path)) {
      throw new ToolFailure('UNSUPPORTED_PREVIEW_FORMAT', 'JSONL previews are no longer supported. Write ordinary JavaScript to a .js file or use self-contained HTML/SVG, then call publish_preview. For Three.js set library="three".', 'write_preview_file');
    }
    if (!/\.(js|svg|html)$/i.test(path)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Preview requires a .js, .html or .svg file.', 'fix_arguments'); }
    const snapshot = await this.files.read(path, cancellation);
    const source = snapshot.content;
    cancellation.check();
    let phase = 'INVALID_FIELD';
    try {
      const script = /\.js$/i.test(path);
      const title = args.title || path.split('/').pop()?.slice(0, 160) || 'Preview';
      const autoHeight = !script && args.height === undefined;
      const spec: WebUiSpec = { version: 1, html: script ? '' : source,
        css: 'html,body{margin:0;width:100%;' + (autoHeight ? 'min-height:100%;' : 'height:100%;') +
          '}svg{display:block;max-width:100%;height:auto;margin:auto;}',
        js: script ? source : '', library: args.library || 'none', height: args.height ?? 400, autoHeight: autoHeight };
      const records: UiRecord[] = [{ op: 'begin', version: 1, title: title, state: {} },
        { op: 'node', node: { id: 'preview', kind: 'web', data: JSON.stringify(spec) } }, { op: 'end' }];
      // Internal serialization only: callers author source files, never this renderer protocol.
      const wire = records.map((record) => JSON.stringify(record)).join('\n');
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
          location: diagnostic.location, locationScope: 'generated_wrapper',
          excerpt: diagnostic.excerpt, repair: repairGuidance(diagnostic.code, path, args.title, args.library, args.height) });
    }
  }
}
