import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { EmbeddedLinux } from './EmbeddedLinux';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import native from 'libtinybot_sandbox.so';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { ToolFailure, ToolResultError, parseToolArguments } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { readBounded, writeBytes } from './FileBytes';
import { FileJobWorkspace } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';

const HALF = 2 * 1024 * 1024;
const FILE_LIMIT = 1024 * 1024;
interface LinuxArguments { language: string; source: string; inputPath?: string; outputPath?: string; }
interface GuestRequest { language: string; source: string; collect: boolean; input?: string; }
interface GuestResponse { exitCode: number; stdout: string; stderr: string; truncated: boolean; error?: string; artifact?: string; }
interface LinuxReceipt { exitCode: number; stdout: string; stderr: string; truncated: boolean; outputPath?: string; bytes?: number; }

export class LinuxTools implements AgentTools {
  private static busy: boolean = false;
  private static phoneVm: EmbeddedLinux = new EmbeddedLinux();
  private context: common.Context;
  private files: FileJobWorkspace;
  constructor(context: common.Context, files: FileJobWorkspace) { this.context = context; this.files = files; }
  static available(): boolean { return typeof native.startLinux === 'function'; }
  definitions(): ToolDefinition[] {
    return [{ type: 'function', executionMode: 'sequential', function: { name: 'run_linux',
      description: 'Run shell or Python in a fresh offline ARM64 Alpine guest. Python sqlite3 and the sqlite3 CLI are installed. ' +
        'The working directory is /work. Optional inputPath copies one private workspace file (up to 1 MiB) to /work/input. ' +
        'To create a new workspace file, set outputPath and write /work/output (up to 1 MiB). Guest changes expire after the job. ' +
        'Returns exitCode, stdout and stderr. Limit 120 seconds, 16 KiB per output stream.',
      parameters: { type: 'object', properties: {
        'language': { type: 'string', description: 'Interpreter.', enum: ['shell', 'python'] },
        'source': { type: 'string', description: 'Program source.' },
        'inputPath': { type: 'string', description: 'Optional private input file.' },
        'outputPath': { type: 'string', description: 'Optional new output file.' }
      }, required: ['language', 'source'], additionalProperties: false } } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'run_linux' || !LinuxTools.available()) {
      throw new ToolFailure('TOOL_UNAVAILABLE', 'Linux runtime is unavailable in this build.', 'check_available_tools');
    }
    if (context?.workspaceWrite !== undefined) {
      throw new ToolFailure('PERMISSION_DENIED', 'This context restricts workspace writes.', 'check_permissions');
    }
    const args = parseToolArguments(call.function.arguments) as LinuxArguments;
    if (!args || !['shell', 'python'].includes(args.language) || typeof args.source !== 'string' ||
      !args.source.trim() || args.source.length > 32768 ||
      Object.keys(args).some((key: string) => !['language', 'source', 'inputPath', 'outputPath'].includes(key)) ||
      (args.inputPath !== undefined && typeof args.inputPath !== 'string') ||
      (args.outputPath !== undefined && typeof args.outputPath !== 'string')) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected shell or python, up to 32768 characters of source, and optional file paths.', 'fix_arguments');
    }
    const input = args.inputPath === undefined ? undefined : workspaceRelativePath(args.inputPath, false);
    const output = args.outputPath === undefined ? undefined : workspaceRelativePath(args.outputPath, false);
    if (LinuxTools.busy) { throw new ToolFailure('BUSY', 'A Linux guest is running.', 'wait_then_check'); }
    LinuxTools.busy = true;
    const id = util.generateRandomUUID();
    const dir = this.context.cacheDir + '/linux-' + id;
    let created = false;
    try {
      await fs.mkdir(dir);
      created = true;
      const request: GuestRequest = { language: args.language, source: args.source, collect: output !== undefined };
      const base64 = new util.Base64Helper();
      if (input !== undefined) { request.input = base64.encodeToStringSync(await this.files.readJobInput(input, FILE_LIMIT, cancellation)); }
      const packet = new util.TextEncoder().encodeInto(JSON.stringify(request));
      if (packet.byteLength > HALF - 8) { throw new ToolFailure('LIMIT_EXCEEDED', 'Request exceeds exchange disk.', 'reduce_input'); }
      const disk = new Uint8Array(2 * HALF);
      disk.set([84, 66, 74, 49]);
      new DataView(disk.buffer).setUint32(4, packet.byteLength, true);
      disk.set(packet, 8);
      const separateProcess = deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === '2in1';
      if (separateProcess || !LinuxTools.phoneVm.initialized) {
        await writeBytes(dir + '/exchange', disk.buffer as ArrayBuffer);
        for (const name of ['kernel', 'root.qcow2']) {
          cancellation.check();
          const bytes = await this.context.resourceManager.getRawFileContent('linux/' + name);
          await writeBytes(dir + '/' + name, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length));
        }
      }
      cancellation.check();
      let diagnostics: string = '';
      let buffer: ArrayBuffer;
      if (separateProcess) {
        const pending = native.startLinux(id, dir);
        const unsubscribe = cancellation.onCancel(() => { native.cancelLinux(id); });
        try { diagnostics = await pending; } finally { unsubscribe(); cancellation.check(); }
        const handle = await fs.open(dir + '/exchange', fs.OpenMode.READ_ONLY);
        try { buffer = await readBounded(handle.fd, 2 * HALF); } finally { await fs.close(handle); }
      } else {
        buffer = await LinuxTools.phoneVm.run(dir, disk.buffer as ArrayBuffer, cancellation);
        cancellation.check();
      }
      const header = new DataView(buffer, HALF, 8);
      const length = header.getUint32(4, true);
      if (header.getUint32(0, false) !== 0x54425231 || length < 2 || length > HALF - 8) {
        throw new ToolFailure('EXECUTION_FAILED', 'Linux guest exited without a valid receipt. ' + diagnostics, 'inspect_result_before_retry');
      }
      const json = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(buffer, HALF + 8, length));
      const result = JSON.parse(json) as GuestResponse;
      if (result.error) { throw new ToolFailure('EXECUTION_FAILED', result.error, 'fix_code'); }
      if (!Number.isInteger(result.exitCode) || typeof result.stdout !== 'string' || typeof result.stderr !== 'string' ||
        typeof result.truncated !== 'boolean') { throw new ToolFailure('INVALID_RESPONSE', 'Invalid Linux result.', 'inspect_result_before_retry'); }
      const receipt: LinuxReceipt = { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, truncated: result.truncated };
      if (receipt.exitCode !== 0) { throw new ToolResultError(JSON.stringify(receipt), 'EXECUTION_FAILED', 'fix_code'); }
      if (output !== undefined) {
        if (typeof result.artifact !== 'string') { throw new ToolFailure('INVALID_RESPONSE', 'Missing Linux output.', 'inspect_result_before_retry'); }
        const bytes = result.artifact.length ? base64.decodeSync(result.artifact) : new Uint8Array(0);
        if (bytes.length > FILE_LIMIT) { throw new ToolFailure('LIMIT_EXCEEDED', 'Linux output exceeds 1 MiB.', 'reduce_input'); }
        cancellation.check();
        await this.files.createJobOutput(output, bytes, cancellation);
        receipt.outputPath = output; receipt.bytes = bytes.length;
      }
      return JSON.stringify(receipt);
    } finally {
      try { if (created) { await fs.rmdir(dir); } } finally { LinuxTools.busy = false; }
    }
  }
}
