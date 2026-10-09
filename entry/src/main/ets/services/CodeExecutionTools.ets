import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

export interface CodeExecutor {
  execute(source: string, inputJson: string, cancellation: Cancellation): Promise<string>;
}

interface CodeArguments { code: string; input?: string; }

export class CodeExecutionTools implements AgentTools {
  private executor: CodeExecutor;
  constructor(executor: CodeExecutor) { this.executor = executor; }

  definitions(): ToolDefinition[] {
    // The native adapter admits one job until its runtime has finished cleanup.
    return [{ type: 'function', executionMode: 'sequential', function: {
      name: 'execute_code',
      description: 'Run synchronous JavaScript for calculation, parsing and data transformation in a fresh isolated QuickJS runtime. ' +
        'code is a function body: read the input variable and use return for a JSON-serializable result. ' +
        'console.log/info and console.warn/error capture logs. No filesystem, network, timers, Node.js, npm, module imports or host tools. ' +
        'Promises/async work are unsupported. Use read_file before execution and write_file afterwards for files. ' +
        'Runtime limits: 2 seconds, 32 MiB runtime allocations and 32 KiB combined logs. No separate code/input/result size caps. ' +
        'Returns status, stdout, stderr, result, error, logsTruncated, resultTruncated and durationMs. Pure computation is available in read-only mode.',
      parameters: { type: 'object', properties: {
        'code': { type: 'string', description: 'JavaScript function body, e.g. return input.values.reduce((a, b) => a + b, 0);' },
        'input': { type: 'string', description: 'Optional JSON-encoded input, e.g. {"values":[1,2,3]}; defaults to null.' }
      }, required: ['code'], additionalProperties: false }
    } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'execute_code') { throw new Error('Unsupported code execution tool'); }
    let args: CodeArguments;
    try { args = JSON.parse(call.function.arguments) as CodeArguments; }
    catch (_) { throw new Error('Code tool arguments must be a JSON object'); }
    if (!args || typeof args !== 'object' || Array.isArray(args) || typeof args.code !== 'string' || !args.code.trim() ||
      Object.keys(args).some((key: string) => key !== 'code' && key !== 'input') ||
      (args.input !== undefined && typeof args.input !== 'string')) { throw new Error('Expected code and optional JSON input strings'); }
    const input = args.input === undefined ? 'null' : args.input;
    // Native parsing keeps JSON depth, allocation and parse work inside the runtime budget.
    const output = await this.executor.execute(args.code, input, cancellation);
    cancellation.check();
    return output;
  }
}
