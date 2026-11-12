import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import sandbox, { LocalProcessReceipt } from 'libtinybot_sandbox.so';
import { ApiLevel } from '../common/ApiLevel';
import { IS_PC } from '../common/DeviceForm';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { Diagnostics } from '../model/Diagnostics';
import { parseToolArguments, ToolFailure, ToolResultError } from '../model/ToolFailure';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

interface LocalProcessArguments {
  runtime: string;
  code: string;
  input?: string;
  timeoutMs?: number;
}

export function localProcessDirectory(context?: common.Context): string | undefined {
  if (ApiLevel.sdk < 26 || !IS_PC || !context) { return undefined; }
  const path = context.applicationInfo.nativeLibraryPath;
  if (!path) { return undefined; }
  const directory = path.startsWith('/') ? path : context.bundleCodeDir + '/' + path;
  return sandbox.localProcessAvailable(directory) ? directory : undefined;
}

export class LocalProcessTools implements AgentTools {
  private directory: string;

  constructor(directory: string) { this.directory = directory; }

  definitions(): ToolDefinition[] {
    return [{ type: 'function', executionMode: 'sequential', function: {
      name: 'run_local_command',
      description: 'Run one script in a separate HarmonyOS PC process using the packaged Node.js or POSIX shell. ' +
        'Pass text in input (stdin) and return text through stdout. The process has an isolated filesystem and network. ' +
        'Use the workspace file tools to read inputs and save results. No workspace paths, npm dependencies, native addons, ' +
        'interactive terminal, or background jobs. Returns stdout, stderr, status, exitCode or signal, and durationMs. ' +
        'Limits: 16 KiB source, 32 KiB stdin, 16 KiB per output stream and 60 seconds. One command can run at a time.',
      parameters: { type: 'object', properties: {
        'runtime': { type: 'string', enum: ['node', 'shell'], description: 'Choose Node.js or the POSIX shell.' },
        'code': { type: 'string', description: 'JavaScript source or POSIX shell commands, according to runtime.' },
        'input': { type: 'string', description: 'Optional UTF-8 text passed on stdin.' },
        'timeoutMs': { type: 'integer', description: 'Wall-clock limit in milliseconds, 1 to 60000. Defaults to 10000.' }
      }, required: ['runtime', 'code'], additionalProperties: false }
    } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'run_local_command') {
      throw new ToolFailure('TOOL_UNAVAILABLE', 'Unsupported local execution tool', 'check_available_tools');
    }
    const args = parseToolArguments(call.function.arguments) as LocalProcessArguments;
    if (!args || typeof args !== 'object' || Array.isArray(args) ||
      (args.runtime !== 'node' && args.runtime !== 'shell') || typeof args.code !== 'string' ||
      !args.code.trim() || args.code.includes('\u0000') ||
      (args.input !== undefined && typeof args.input !== 'string') ||
      Object.keys(args).some((key: string) => !['runtime', 'code', 'input', 'timeoutMs'].includes(key))) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected node or shell, code and optional text input and timeoutMs', 'fix_arguments');
    }
    const timeout = args.timeoutMs === undefined ? 10000 : args.timeoutMs;
    const input = args.input ?? '';
    const encoder = new util.TextEncoder();
    if (!Number.isInteger(timeout) || timeout < 1 || timeout > 60000 ||
      encoder.encodeInto(args.code).byteLength > 16 * 1024 || encoder.encodeInto(input).byteLength > 32 * 1024) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Local command source, stdin or timeoutMs exceeds its limit', 'fix_arguments');
    }
    const id = util.generateRandomUUID();
    let remove = (): void => {};
    let receipt: LocalProcessReceipt;
    try {
      const pending = sandbox.runLocalProcess(id, this.directory, args.runtime, args.code, input, timeout);
      remove = cancellation.onCancel(() => sandbox.cancelLocalProcess(id));
      receipt = await pending;
    } catch (error) {
      Diagnostics.log('error', 'sandbox', 'local_process_failed', { sessionId: id }, error as Error);
      throw error as Error;
    } finally { remove(); }
    cancellation.check();
    if (receipt.status !== 'ok') {
      if (receipt.error) {
        Diagnostics.log('error', 'sandbox', 'local_process_failed', { sessionId: id }, receipt.error);
      } else if (receipt.exitCode !== undefined) {
        receipt.error = 'Local command exited with code ' + receipt.exitCode;
      } else if (receipt.signal !== undefined) {
        receipt.error = 'Local command terminated by signal ' + receipt.signal;
      } else if (receipt.status === 'timeout') {
        receipt.error = 'Local command exceeded its time limit';
      }
      const code = receipt.status === 'timeout' ? 'TIMEOUT' : receipt.status === 'cancelled' ? 'CANCELLED' : 'EXECUTION_FAILED';
      throw new ToolResultError(JSON.stringify(receipt), code);
    }
    return JSON.stringify(receipt);
  }
}
