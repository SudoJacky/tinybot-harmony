import { common } from '@kit.AbilityKit';
import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { LinuxJob, linuxRuntime } from './LinuxRuntime';
import { LinuxWorkspaceScope } from './LinuxWorkspace';
import { FileJobWorkspace } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';

export class LinuxTools implements AgentTools {
  private context: common.Context;
  private files: FileJobWorkspace;
  private scope?: LinuxWorkspaceScope;

  constructor(context: common.Context, files: FileJobWorkspace, scope?: LinuxWorkspaceScope) {
    this.context = context;
    this.files = files;
    this.scope = scope;
  }

  definitions(): ToolDefinition[] {
    if (!linuxRuntime.toolEnabled) { return []; }
    const settings = linuxRuntime.snapshot().settings;
    const properties: Record<string, ToolProperty> = {
      'language': { type: 'string', description: 'Interpreter.', enum: ['shell', 'python'] },
      'source': { type: 'string', description: 'Program source.' }
    };
    let description = 'Run shell or Python in a fresh offline ARM64 Alpine guest. Python sqlite3 and the sqlite3 CLI are installed. ' +
      'The working directory is /work. Guest changes expire after the job. ';
    if (settings.allowInput) {
      properties.inputPath = { type: 'string', description: 'Optional private input file.' };
      description += 'Optional inputPath copies one private workspace file (up to 1 MiB) to /work/input. ';
    }
    if (settings.allowOutput) {
      properties.outputPath = { type: 'string', description: 'Optional new output file.' };
      description += 'To create a new workspace file, set outputPath and write /work/output (up to 1 MiB). ';
    }
    if (this.scope && settings.allowInput) {
      description += 'User-mounted local directories are available read-only under $TINYBOT_MOUNTS_DIR when present. ';
      if (this.scope.project && settings.allowOutput) {
        description += 'If enabled for the current project, $TINYBOT_PROJECT_DIR is a writable directory saved after a successful job. ';
      }
    }
    description += 'Returns exitCode, stdout and stderr. Limit ' + settings.timeoutSeconds + ' seconds, 16 KiB per output stream.';
    return [{ type: 'function', executionMode: 'sequential', function: { name: 'run_linux', description: description,
      parameters: { type: 'object', properties: properties, required: ['language', 'source'], additionalProperties: false } } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'run_linux') {
      throw new ToolFailure('TOOL_UNAVAILABLE', 'Linux runtime cannot execute this tool.', 'check_available_tools');
    }
    if (context?.workspaceWrite !== undefined) {
      throw new ToolFailure('PERMISSION_DENIED', 'This context restricts workspace writes.', 'check_permissions');
    }
    const args = parseToolArguments(call.function.arguments) as LinuxJob;
    if (!args || !['shell', 'python'].includes(args.language) || typeof args.source !== 'string' ||
      !args.source.trim() || args.source.length > 32768 ||
      Object.keys(args).some((key: string) => !['language', 'source', 'inputPath', 'outputPath'].includes(key)) ||
      (args.inputPath !== undefined && typeof args.inputPath !== 'string') ||
      (args.outputPath !== undefined && typeof args.outputPath !== 'string')) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected shell or python, up to 32768 characters of source, and optional file paths.', 'fix_arguments');
    }
    const job: LinuxJob = { language: args.language, source: args.source,
      inputPath: args.inputPath === undefined ? undefined : workspaceRelativePath(args.inputPath, false),
      outputPath: args.outputPath === undefined ? undefined : workspaceRelativePath(args.outputPath, false) };
    return JSON.stringify(await linuxRuntime.runTool(this.context, job, this.files, cancellation, this.scope));
  }
}
