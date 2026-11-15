import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ToolCall, ToolDefinition, ToolExecution, toolError } from '../model/Agent';
import { parseToolArguments, ToolFailure, ToolResultError } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { WorkspaceCodeExecutor } from './CodeExecutionTools';
import { OrchestrationExecutor } from './OrchestrationTools';
import { FileJobWorkspace } from './WorkspaceFiles';
import { WorkspaceTools, workspaceRelativePath } from './WorkspaceTools';

const MAX_BYTES = 20 * 1024 * 1024;
const OFFICE_EXTENSION = /\.(docx|xlsx|pptx)$/i;
const BRIDGE_CATALOG = '[{"name":"read_bytes"},{"name":"read_text"},{"name":"write_text"},{"name":"write_office"},{"name":"review_pptx"}]';

interface Arguments { path: string; data?: string; replace?: boolean; }
interface Receipt { path: string; bytes: number; written?: boolean; }
interface FileOperation { path: string; operation: string; status: string; }
interface FileIssue { path: string; receipt: Object; }
interface CodeResult { status: string; files?: FileOperation[]; issues?: FileIssue[]; }

const GUIDE = 'Use await workspace.read(path) for private-workspace bytes or await workspace.readText(path) for UTF-8 text. ' +
  'Use await workspace.write(path, textOrOfficeBytes); it returns a small file receipt. Overwrite text only after readText or read_file; ' +
  'Office outputs normally require a new private workspace path. For your own existing PPTX draft, read with workspace.read in the same call, edit the bytes, then use workspace.write(path, bytes, {replace:true}); the observed version must still match. Permissions are checked on every call. ' +
  'The bundled office library supports office.text(bytes), office.xlsx([{name:"Sheet1",rows:[["Item",12],[null,{formula:"B1+1"}]]}]), ' +
  'office.docx([{heading:"Title",level:1},{text:"Paragraph"},{table:[["Item","Value"]]}]), office.pptx([{title:"Overview",body:["Point"]}]), ' +
  'office.editXlsx(bytes,[{sheet:"Sheet1",cell:"B2",value:15}]), office.editDocx(bytes,[{find:"old",replace:"new"}]), and ' +
  'office.editPptx(bytes,[{slide:1,find:"old",replace:"new"}]). Text replacement requires unique text within one paragraph. ' +
  'For PPTX, start with office.pptx({theme:{name,fontFace,background,text,muted,accent,accent2},slides:[{layout:"cover"|"chart"|"summary",title,subtitle,source,points:["Short takeaway"],metrics:[{value:"12%",label:"Growth"}],charts:[{chart:"bar",categories:["2024","2025"],series:[{name:"Revenue",values:[10,12]}]}]}]}). ' +
  'Cover takes metrics, summary takes up to four points and metrics, chart takes one chart and up to three brief points or two charts and one point. Omit unused fields. Use one takeaway per slide and keep detailed evidence in the appendix. ' +
  'Before delivering a PPTX, call await workspace.reviewPptx(bytes). It renders every page using Tinybot preview and reports overlap, overflow, off-slide objects and small body text by page and element. Fix issues and rerun review on the revised bytes before saving. Return only compact results (e.g. review.pages.filter(p=>p.issueCount)). ' +
  'For custom layouts use slides:[{background,elements}] instead. ' +
  'Each element needs a unique id per slide and x,y,w,h in inches on a 13⅓ × 7.5 slide. Array order is back to front. Optional rotate is in degrees. ' +
  'Types: text (text,fontSize in points,fontFace,color,bold,italic,align,verticalAlign); image (data: await workspace.read(path) for PNG/JPEG,alt); ' +
  'shape (shape: rect,roundRect,ellipse,triangle,diamond,hexagon,chevron,rightArrow,star5,line). Text and shapes accept fill,stroke,strokeWidth in points. ' +
  'type:"chart" adds an editable chart with an embedded workbook. Use chart:"bar"|"line"|"doughnut", categories:["Q1","Q2"], series:[{name:"Revenue",values:[12,18]}], optional title, legend and colors. Doughnut uses one nonnegative series. ' +
  'Colors accept six-digit hex or the theme keys background,text,muted,accent,accent2; use none for transparent fill or stroke. ' +
  'To revise a PPT annotation, inspect its slide with office.inspectPptx(bytes,slide), then use office.editPptx(bytes,[{slide,element:elementId,changes:{x,y,fill}}]). ' +
  'Changes may update geometry, text formatting, shape preset, image data or chart data, title, legend and colors; pass {theme} as the third argument for theme changes. ' +
  'Example: const bytes = await workspace.read(input.source); return await workspace.write(input.output, office.editXlsx(bytes,input.edits)); ' +
  'Call present_files for delivery. Await each operation before starting the next; committed writes are kept if later code fails. ' +
  'Limits: 20 MiB total read and 20 MiB total written, 32 operations, 10 seconds of script computation, 120 seconds elapsed, ' +
  '192 MiB runtime memory, and 64 MiB expanded Office archive.';

export function workspaceCodeSource(library: string, code: string, inputJson: string): string {
  return library + '\n' +
    'const bridge = tools; delete globalThis.tools; delete globalThis.ALL_TOOLS;\n' +
    'let active = false;\n' +
    'async function single(work) {\n' +
    '  if (active) throw Error("Await the current workspace operation before starting another.");\n' +
    '  active = true; try { return await work(); } finally { active = false; }\n' +
    '}\n' +
    'const workspace = Object.freeze({\n' +
    '  read: path => single(async () => Uint8Array.fromBase64(await bridge.read_bytes({path}))),\n' +
    '  readText: path => single(() => bridge.read_text({path})),\n' +
    '  reviewPptx: bytes => single(() => {\n' +
    '    if (!(bytes instanceof Uint8Array) || bytes.byteLength > ' + MAX_BYTES + ') throw Error("Expected PPTX bytes up to 20 MiB.");\n' +
    '    return bridge.review_pptx({data:bytes.toBase64()});\n' +
    '  }),\n' +
    '  write: (path, data, options) => single(async () => {\n' +
    '    if (typeof data === "string") return bridge.write_text({path, data});\n' +
    '    const format = typeof path === "string" && /\\.(docx|xlsx|pptx)$/i.exec(path);\n' +
    '    if (!format || !(data instanceof Uint8Array)) throw Error("Expected text or Office bytes with a matching filename.");\n' +
    '    if (data.byteLength > ' + MAX_BYTES + ') throw Error("Office output exceeds 20 MiB.");\n' +
    '    OfficeJob.verify(data, format[1].toLowerCase());\n' +
    '    const replace = options?.replace === true;\n' +
    '    if (replace && format[1].toLowerCase() !== "pptx") throw Error("Only PPTX drafts can be revised in place.");\n' +
    '    return bridge.write_office({path, data:data.toBase64(), replace});\n' +
    '  })\n' +
    '});\n' +
    'const run = Object.getPrototypeOf(async function(){}).constructor("input", "workspace", "office", ' +
    JSON.stringify('"use strict";\n' + code) + ');\n' +
    'return await run(JSON.parse(' + JSON.stringify(inputJson) + '), workspace, Object.freeze(OfficeJob));';
}

class WorkspaceOperation implements AgentTools {
  private action: (signal: Cancellation, context?: ToolInvocationContext) => Promise<string>;
  constructor(action: (signal: Cancellation, context?: ToolInvocationContext) => Promise<string>) { this.action = action; }
  definitions(): ToolDefinition[] { return []; }
  execute(_call: ToolCall, signal: Cancellation, context?: ToolInvocationContext): Promise<string> { return this.action(signal, context); }
}

export class WorkspaceCode implements WorkspaceCodeExecutor {
  private workspace: FileJobWorkspace;
  private textFiles: WorkspaceTools;
  private executor: OrchestrationExecutor;
  private loadLibrary: () => Promise<string>;
  private reviewPptx?: (encoded: string, cancellation: Cancellation) => Promise<string>;

  constructor(workspace: FileJobWorkspace, textFiles: WorkspaceTools, executor: OrchestrationExecutor, loadLibrary: () => Promise<string>,
    reviewPptx?: (encoded: string, cancellation: Cancellation) => Promise<string>) {
    this.workspace = workspace;
    this.textFiles = textFiles;
    this.executor = executor;
    this.loadLibrary = loadLibrary;
    this.reviewPptx = reviewPptx;
  }

  guide(): string { return GUIDE; }

  async execute(code: string, inputJson: string, context: ToolInvocationContext, cancellation: Cancellation): Promise<string> {
    const signal = new Cancellation();
    const unsubscribe = cancellation.onCancel(() => signal.cancel());
    const children: ToolExecution[] = [];
    let readRemaining = MAX_BYTES;
    let writeRemaining = MAX_BYTES;
    const pptxVersions: Map<string, string> = new Map();
    let calls = 0;
    let tail: Promise<void> = Promise.resolve();
    let fatal: Error | undefined;
    const base64 = new util.Base64Helper();
    const version = async (bytes: Uint8Array): Promise<string> => {
      const hash = cryptoFramework.createMd('SHA256');
      if (bytes.length) { await hash.update({ data: bytes }); }
      return await base64.encodeToString((await hash.digest()).data);
    };
    const byteLength = (text: string): number => text.length ? new util.TextEncoder().encodeInto(text).byteLength : 0;
    const limit = (): ToolFailure => new ToolFailure('LIMIT_EXCEEDED', 'Workspace script exceeded 20 MiB in one direction.', 'reduce_input');
    const invoke = (operation: string, json: string): Promise<string> => {
      signal.check();
      if (++calls > 32) { throw new ToolFailure('LIMIT_EXCEEDED', 'Workspace script exceeded 32 operations.', 'reduce_input'); }
      const args = parseToolArguments(json) as Arguments;
      if (operation === 'review_pptx') {
        if (!args || typeof args.data !== 'string' || args.data.length > Math.ceil(MAX_BYTES / 3) * 4) {
          throw new ToolFailure('INVALID_ARGUMENTS', 'Expected PowerPoint bytes up to 20 MiB.', 'fix_arguments');
        }
        if (!this.reviewPptx) { throw new ToolFailure('TOOL_UNAVAILABLE', 'PowerPoint layout review is unavailable.', 'open_chat'); }
        const review = this.reviewPptx;
        const work = tail.then(() => review(args.data as string, signal));
        tail = work.then(() => {}, () => {});
        return work;
      }
      const reading = operation === 'read_bytes' || operation === 'read_text';
      const office = operation === 'write_office';
      if ((!reading && !office && operation !== 'write_text') || !args || typeof args.path !== 'string' ||
        (!reading && typeof args.data !== 'string')) {
        throw new ToolFailure('INVALID_ARGUMENTS', 'Expected a workspace path and valid write data.', 'fix_arguments');
      }
      const path = workspaceRelativePath(args.path, false);
      const name = reading ? 'read_file' : 'write_file';
      const work = tail.then(async (): Promise<string> => {
        signal.check();
        const child: ToolExecution = { call: { id: util.generateRandomUUID(), type: 'function',
          function: { name: name, arguments: JSON.stringify({ path: path }) } }, status: 'pending', output: '' };
        if (!children.length) { context.execution.children = children; }
        children.push(child);
        let response = '';
        const handler = new WorkspaceOperation(async (current, childContext): Promise<string> => {
          current.check();
          if (!reading && (context.workspaceWrite === 'none' || (office && context.workspaceWrite === 'text'))) {
            throw new ToolFailure('PERMISSION_DENIED', 'This session or role cannot perform this workspace write.', 'check_permissions', { path: path });
          }
          const receipt: Receipt = { path: path, bytes: 0 };
          if (operation === 'read_bytes') {
            const bytes = await this.workspace.readJobInput(path, readRemaining, current);
            receipt.bytes = bytes.byteLength;
            if (/\.pptx$/i.test(path)) { pptxVersions.set(path, await version(bytes)); }
            response = JSON.stringify(bytes.byteLength ? await base64.encodeToString(bytes) : '');
          } else if (operation === 'read_text') {
            const text = await this.textFiles.readTextForCode(path, readRemaining, current);
            receipt.bytes = byteLength(text);
            if (receipt.bytes > readRemaining) { throw limit(); }
            response = JSON.stringify(text);
          } else if (office) {
            const data = args.data as string;
            if (data.length > Math.ceil(writeRemaining / 3) * 4) { throw limit(); }
            const bytes = await base64.decode(data);
            if (bytes.byteLength > writeRemaining) { throw limit(); }
            if (!OFFICE_EXTENSION.test(path) || bytes[0] !== 0x50 || bytes[1] !== 0x4B || bytes[2] !== 3 || bytes[3] !== 4) {
              throw new ToolFailure('INVALID_ARGUMENTS', 'Expected a valid Office file and extension.', 'fix_arguments', { path: path });
            }
            const expected = args.replace ? pptxVersions.get(path) : undefined;
            if (args.replace && (!/\.pptx$/i.test(path) || expected === undefined)) {
              throw new ToolFailure('FS_NOT_OBSERVED', 'Read this PowerPoint draft with workspace.read before revising it.', 'read_file', { path: path });
            }
            await this.workspace.createJobOutput(path, bytes, current, expected);
            if (expected !== undefined) { pptxVersions.set(path, await version(bytes)); }
            receipt.bytes = bytes.byteLength;
            receipt.written = true;
          } else {
            const data = args.data as string;
            if (data.length > writeRemaining || byteLength(data) > writeRemaining) { throw limit(); }
            response = await this.textFiles.execute({ id: child.call.id, type: 'function',
              function: { name: name, arguments: JSON.stringify({ path: path, content: data }) } }, current, childContext);
            receipt.bytes = (JSON.parse(response) as Receipt).bytes;
            receipt.written = true;
          }
          if (reading) { readRemaining -= receipt.bytes; }
          else { writeRemaining -= receipt.bytes; }
          return JSON.stringify(receipt);
        });
        try { await context.executeChild(child, handler, signal); }
        catch (error) { if (!signal.cancelled) { fatal = error as Error; signal.cancel(); } throw error as Error; }
        if (child.status !== 'complete') {
          const failure = JSON.parse(child.output) as ToolFailure;
          throw new ToolResultError(child.output, failure.code || 'EXECUTION_FAILED', failure.recovery || 'inspect_result_before_retry');
        }
        return response || child.output;
      });
      tail = work.then(() => {}, () => {});
      return work;
    };
    let result: string;
    try {
      const library = await this.loadLibrary();
      result = await this.executor.execute(workspaceCodeSource(library, code, inputJson), BRIDGE_CATALOG, invoke, signal);
    } finally {
      signal.cancel();
      await tail;
      unsubscribe();
      for (const child of children) {
        if (child.status === 'pending') {
          child.status = 'cancelled';
          child.output = toolError(new ToolFailure('NOT_EXECUTED', 'Script ended before this file operation started.', 'none'));
        }
      }
      if (fatal) { throw fatal as Error; }
    }
    const receipt = JSON.parse(result) as CodeResult;
    if (children.length) {
      receipt.files = children.map((child): FileOperation => ({
        path: (JSON.parse(child.call.function.arguments) as Arguments).path,
        operation: child.call.function.name, status: child.status
      }));
      receipt.issues = children.filter((child) => child.status !== 'complete').map((child): FileIssue => ({
        path: (JSON.parse(child.call.function.arguments) as Arguments).path, receipt: JSON.parse(child.output) as Object
      }));
    }
    return JSON.stringify(receipt);
  }
}
