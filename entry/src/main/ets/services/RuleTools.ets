import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';
export class RuleTools implements AgentTools {
  private inner: AgentTools; private readOnly: boolean;
  constructor(inner: AgentTools, readOnly: boolean) { this.inner = inner; this.readOnly = readOnly; }
  private allowed(name: string): boolean { return !this.readOnly || !['write_file', 'edit_file', 'mcp_call', 'generate_image'].includes(name); }
  definitions(): ToolDefinition[] { return this.inner.definitions().filter((item) => this.allowed(item.function.name)); }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    if (!this.allowed(call.function.name)) { throw new Error(t("只读规则已阻止此次操作。")); }
    return this.inner.execute(call, cancellation);
  }
}
