import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

// The same catalog decides both model visibility and dispatch.
export class ToolSet implements AgentTools {
  private entries: Map<string, AgentTools> = new Map<string, AgentTools>();
  private catalog: ToolDefinition[] = [];

  constructor(groups: AgentTools[]) {
    for (const group of groups) {
      for (const definition of group.definitions()) {
        const name = definition.function.name;
        if (this.entries.has(name)) { throw new Error(t("工具名称重复：") + name); }
        this.entries.set(name, group);
        this.catalog.push(definition);
      }
    }
  }

  definitions(): ToolDefinition[] { return this.catalog.slice(); }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const group = this.entries.get(call.function.name);
    if (!group) { throw new Error(t("工具未启用或不存在：") + call.function.name); }
    return group.execute(call, cancellation);
  }
}
