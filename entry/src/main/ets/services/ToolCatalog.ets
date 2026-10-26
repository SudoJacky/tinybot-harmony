import { ToolCall, ToolDefinition } from '../model/Agent';
import { ToolFailure } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';

// Request preparation and the context inspector use the same complete, authorized catalog.
export function orderedToolDefinitions(catalog: ToolDefinition[]): ToolDefinition[] {
  if (catalog.some((tool) => tool.function.name === 'tool_search')) {
    throw new ToolFailure('INTERNAL_ERROR', 'Reserved tool name: tool_search', 'inspect_error');
  }
  return catalog.slice().sort((a, b) => a.function.name < b.function.name ? -1 : a.function.name > b.function.name ? 1 : 0);
}

export class ToolCatalog implements AgentTools {
  private inner: AgentTools;
  constructor(inner: AgentTools) { this.inner = inner; }
  definitions(): ToolDefinition[] { return orderedToolDefinitions(this.inner.definitions()); }
  beforeFinish(cancellation: Cancellation): Promise<string | undefined> {
    return this.inner.beforeFinish ? this.inner.beforeFinish(cancellation) : Promise.resolve(undefined);
  }
  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    // Old receipts remain readable, but a new call cannot reactivate the retired search tool.
    if (call.function.name === 'tool_search') {
      throw new ToolFailure('TOOL_UNAVAILABLE', 'tool_search has been removed. Enabled tools are provided directly.', 'check_available_tools');
    }
    return this.inner.execute(call, cancellation, context);
  }
}
