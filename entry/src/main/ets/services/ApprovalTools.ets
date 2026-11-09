import { ToolCall, ToolDefinition } from '../model/Agent';
import { TOOL_GROUPS } from '../model/ToolGroups';
import { parseToolArguments } from '../model/ToolFailure';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { ToolApproval } from './ToolApproval';

// MCP calls validate discovery and display the remote endpoint before asking in McpTools.
const APPROVAL_TOOLS = new Set(TOOL_GROUPS.filter((group) => !group.readOnly).flatMap((group) => group.tools)
  .filter((name) => name !== 'mcp_call' && name !== 'validate_life_panel'));

interface ApprovalArguments { action?: string; }

export class ApprovalTools implements AgentTools {
  private inner: AgentTools;
  private approval: ToolApproval;
  private threadTitle: string;

  constructor(inner: AgentTools, approval: ToolApproval, threadTitle: string) {
    this.inner = inner;
    this.approval = approval;
    this.threadTitle = threadTitle;
  }

  definitions(): ToolDefinition[] { return this.inner.definitions(); }

  beforeFinish(cancellation: Cancellation): Promise<string | undefined> {
    return this.inner.beforeFinish ? this.inner.beforeFinish(cancellation) : Promise.resolve(undefined);
  }

  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    cancellation.check();
    const name = call.function.name;
    if (APPROVAL_TOOLS.has(name) && this.definitions().some((definition) => definition.function.name === name)) {
      const args = parseToolArguments(call.function.arguments) as ApprovalArguments;
      if (name !== 'mcp_manage' || (args?.action !== 'list' && args?.action !== 'test')) {
        await this.approval.request(this.threadTitle + ' · ' + name, call.function.arguments, cancellation);
      }
    }
    return this.inner.execute(call, cancellation, context);
  }
}
