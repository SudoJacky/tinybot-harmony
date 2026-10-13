import { toolEnabled, ToolSelection } from '../model/AgentMode';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { ToolFailure } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { AgentTools, ToolInvocationContext } from './AgentLoop';
import { Cancellation } from './Cancellation';

// The same selection gates the catalog and dispatch, including SDK children.
export class SelectedTools implements AgentTools {
  private inner: AgentTools;
  private selection: ToolSelection;
  constructor(inner: AgentTools, selection: ToolSelection) {
    this.inner = inner; this.selection = { agentMode: selection.agentMode, disabledTools: selection.disabledTools?.slice() };
  }
  definitions(): ToolDefinition[] { return this.inner.definitions().filter((tool) => toolEnabled(tool.function.name, this.selection)); }
  beforeFinish(cancellation: Cancellation): Promise<string | undefined> {
    return this.inner.beforeFinish ? this.inner.beforeFinish(cancellation) : Promise.resolve(undefined);
  }
  async execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string> {
    if (!toolEnabled(call.function.name, this.selection)) {
      throw new ToolFailure('PERMISSION_DENIED', t('此工具已在当前会话中关闭。'), 'check_permissions');
    }
    return this.inner.execute(call, cancellation, context);
  }
}
