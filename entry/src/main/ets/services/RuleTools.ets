import { ToolFailure } from '../model/ToolFailure';
import { TOOL_GROUPS } from '../model/ToolGroups';
import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';
export class RuleTools implements AgentTools {
  private inner: AgentTools; private readOnly: boolean;
  constructor(inner: AgentTools, readOnly: boolean) { this.inner = inner; this.readOnly = readOnly; }
  private allowed(name: string): boolean { return !this.readOnly || !TOOL_GROUPS.some((group) => !group.readOnly && group.tools.includes(name)); }
  definitions(): ToolDefinition[] { return this.inner.definitions().filter((item) => this.allowed(item.function.name)); }
  beforeFinish(cancellation: Cancellation): Promise<string | undefined> {
    return this.inner.beforeFinish ? this.inner.beforeFinish(cancellation) : Promise.resolve(undefined);
  }
  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    if (!this.allowed(call.function.name)) { throw new ToolFailure('PERMISSION_DENIED', t("只读规则已阻止此次操作。"), 'check_permissions'); }
    return this.inner.execute(call, cancellation, context);
  }
}
