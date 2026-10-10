import { ToolCall, ToolDefinition, ToolExecution, validateToolCalls } from '../model/Agent';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { ToolResultError } from './ToolExecution';

export interface OrchestrationExecutor {
  execute(source: string, catalog: string, invoke: (name: string, argumentsJson: string) => Promise<string>,
    cancellation: Cancellation): Promise<string>;
}
interface CodeArguments { code: string; }
interface ChildReference { callId: string; tool: string; status: string; }
interface ExecutionStatus { status: string; calls?: ChildReference[]; }
interface CatalogEntry { name: string; description: string; parameters: Object; }
const NESTED_TOOLS: string[] = ['list_files', 'read_file', 'read_file_lines', 'read_attachment', 'search_file_content',
  'write_file', 'edit_file', 'read_web', 'read_skill', 'mcp_list_tools', 'mcp_search_tools', 'mcp_call', 'read_tool_result'];

// Wrap the final policy-filtered catalog, outside any TeamToolLane. Only children enter that lane.
export class OrchestrationTools implements AgentTools {
  private inner: AgentTools;
  private executor: OrchestrationExecutor;
  constructor(inner: AgentTools, executor: OrchestrationExecutor) { this.inner = inner; this.executor = executor; }
  private nested(): ToolDefinition[] { return this.inner.definitions().filter((tool) => NESTED_TOOLS.includes(tool.function.name)); }
  definitions(): ToolDefinition[] {
    return this.inner.definitions().concat([{ type: 'function', executionMode: 'sequential', function: {
      name: 'orchestrate',
      description: 'Run an async JavaScript function body to compose tools and return one JSON result. ' +
        'Use await tools.NAME({...}); tool outputs are parsed JSON when valid, otherwise strings. ' +
        'ALL_TOOLS contains available names, descriptions and parameter schemas. Existing direct tool schemas also apply. ' +
        'Independent reads may use Promise.all/allSettled; await dependent operations and every tool call before returning. ' +
        'as_settled(iterableOrMap) returns an async iterator in completion order: {index,status,value} or {index,status,reason}; ' +
        'index is the iterable position or Map key. Rejection reasons may be Error objects; use String(reason) in JSON summaries. ' +
        'await stream_settled(iterableOrMap, async result => {...}) processes each outcome with an awaited callback. ' +
        'These helpers do not cancel tasks; consume all outcomes or await remaining calls before returning. ' +
        'text(value) appends a string or JSON to stdout; console logs are also captured (32 KiB combined, truncation flagged). ' +
        'Logs arrive with the final tool receipt, not live. Return the final JSON summary explicitly. ' +
        'Tool failures reject; report partial failures explicitly. ' +
        'No direct network, filesystem, modules, timers or nested orchestration. Permissions and MCP approvals still apply. ' +
        'Limits: 32 calls, 4 active host tools, 2 seconds script computation, 120 seconds elapsed, 32 MiB JS memory, 1 MiB result. ' +
        'Return a compact summary and artifact paths; full child receipts remain in the conversation. ' +
        'Use direct calls for simple one-step work and Team/user-interaction tools. Available nested tools: ' +
        this.nested().map((tool) => tool.function.name).join(', '),
      parameters: { type: 'object', properties: { 'code': { type: 'string',
        description: 'Async function body. Example: const r = await tools.read_file({path:"data.json"}); return JSON.parse(r.content).length;' }
      }, required: ['code'], additionalProperties: false }
    } }]);
  }
  beforeFinish(cancellation: Cancellation): Promise<string | undefined> {
    return this.inner.beforeFinish ? this.inner.beforeFinish(cancellation) : Promise.resolve(undefined);
  }
  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    if (call.function.name !== 'orchestrate') { return this.inner.execute(call, cancellation, context); }
    cancellation.check();
    const args = JSON.parse(call.function.arguments) as CodeArguments;
    if (!args || Array.isArray(args) || typeof args.code !== 'string' || !args.code.trim() || Object.keys(args).some((key) => key !== 'code')) {
      throw new Error('Expected an object containing only a non-empty code string');
    }
    if (!context) { throw new Error('Orchestration requires a durable tool invocation context'); }
    const invocation = context;
    const catalog = this.nested();
    const signal = new Cancellation();
    const unsubscribe = cancellation.onCancel(() => signal.cancel());
    const children: ToolExecution[] = []; invocation.execution.children = children;
    let fatal: Error | undefined = undefined;
    let tail: Promise<void> = Promise.resolve();
    const readers: Promise<void>[] = [];
    const admitted: Promise<void>[] = [];
    // Four lanes bound concurrent host work; serial operations form a barrier across them.
    const slots: Promise<void>[] = [Promise.resolve(), Promise.resolve(), Promise.resolve(), Promise.resolve()];
    let slot = 0;
    const invoke = (name: string, argumentsJson: string): Promise<string> => {
      signal.check();
      const definition = catalog.find((tool) => tool.function.name === name);
      if (!definition || !this.nested().some((tool) => tool.function.name === name)) { throw new Error('Tool unavailable: ' + name); }
      if (children.length >= 32) { throw new Error('Orchestration exceeded 32 tool calls'); }
      const child: ToolExecution = { call: { id: call.id.slice(0, 115) + '_child_' + (children.length + 1),
        type: 'function', function: { name: name, arguments: argumentsJson } }, status: 'pending', output: '' };
      validateToolCalls([child.call]); children.push(child);
      const serial = definition.executionMode === 'sequential';
      const index = slot++ % slots.length;
      const ready = serial ? Promise.all([tail, ...readers]).then(() => {}) : Promise.all([tail, slots[index]]).then(() => {});
      const work = ready.then(async (): Promise<string> => {
        signal.check();
        try { await invocation.executeChild(child, this.inner, signal); }
        catch (error) { fatal = error as Error; signal.cancel(); throw error as Error; }
        if (child.status !== 'complete') { throw new Error(child.output); }
        return child.output;
      });
      const settled = work.then(() => {}, () => {}); admitted.push(settled);
      if (serial) { tail = settled; readers.length = 0; }
      else { slots[index] = settled; readers.push(settled); }
      return work;
    };
    let result = '';
    try {
      result = await this.executor.execute(args.code,
        JSON.stringify(catalog.map((tool): CatalogEntry => ({ name: tool.function.name,
          description: tool.function.description, parameters: tool.function.parameters }))), invoke, signal);
    } finally {
      signal.cancel();
      await Promise.all(admitted);
      unsubscribe();
      for (const child of children) {
        if (child.status === 'pending') { child.status = 'cancelled'; child.output = JSON.stringify({ error: 'Orchestration ended before this call started' }); }
      }
      if (fatal) { throw fatal as Error; }
    }
    cancellation.check();
    const status = JSON.parse(result) as ExecutionStatus;
    status.calls = children.map((child): ChildReference => ({ callId: child.call.id, tool: child.call.function.name, status: child.status }));
    const output = JSON.stringify(status);
    if (status.status !== 'ok') { throw new ToolResultError(output); }
    return output;
  }
}
