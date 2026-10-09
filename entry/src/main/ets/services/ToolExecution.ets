import { AgentStep, ToolDefinition, ToolExecution, ToolExecutionMode, toolError } from '../model/Agent';
import { UsageToolActivity } from '../model/Usage';
import { AgentTools, LoopObserver } from './AgentLoop';
import { Cancellation, RunCancelledError } from './Cancellation';

// Execution order may differ from source order; the step's receipt array never moves.
export async function executeToolBatch(step: AgentStep, round: number, tools: AgentTools,
  definitions: ToolDefinition[], cancellation: Cancellation, observer: LoopObserver,
  mode: ToolExecutionMode = 'parallel'): Promise<void> {
  const sequential = mode === 'sequential' || step.tools.some((tool) =>
    definitions.find((definition) => definition.function.name === tool.call.function.name)?.executionMode === 'sequential');
  let saves: Promise<void> = Promise.resolve();
  const checkpoint = (): Promise<void> => {
    const work = saves.then(() => observer.checkpoint());
    // A failed save is returned to its caller; later completed receipts still get saved.
    saves = work.then(() => {}, () => {});
    return work;
  };
  const prepare = async (batch: ToolExecution[]): Promise<void> => {
    cancellation.check();
    for (const tool of batch) { tool.status = 'running'; }
    try {
      // Persist every intent before starting any effects in this batch.
      await checkpoint();
      cancellation.check();
    } catch (error) {
      for (const tool of batch) { tool.status = 'pending'; }
      throw error as Error;
    }
  };
  const execute = async (tool: ToolExecution): Promise<void> => {
    if (cancellation.cancelled) { tool.status = 'pending'; cancellation.check(); }
    observer.event({ type: 'tool_start', step: round, toolCallId: tool.call.id });
    if (cancellation.cancelled) { tool.status = 'pending'; cancellation.check(); }
    const activity: UsageToolActivity = { id: tool.call.id, name: tool.call.function.name,
      status: 'running', startedAt: Date.now(), durationMs: 0 };
    try {
      const args = JSON.parse(tool.call.function.arguments) as Record<string, string>;
      if (activity.name === 'read_skill' && typeof args.name === 'string') { activity.skill = args.name.slice(0, 120); }
      if (activity.name === 'mcp_call') {
        if (typeof args.server === 'string') { activity.server = args.server.slice(0, 120); }
        if (typeof args.tool === 'string') { activity.remoteTool = args.tool.slice(0, 120); }
      }
    } catch (_) { /* Invalid arguments are handled by the tool. */ }
    const recordActivity = (): void => {
      if (!step.usage) { return; }
      try { observer.toolActivity?.(step.usage.id, activity); } catch (_) { /* Telemetry cannot stop a task. */ }
    };
    recordActivity();
    try {
      tool.output = await tools.execute(tool.call, cancellation);
      tool.status = 'complete';
    } catch (error) {
      tool.output = toolError((error as Error).message);
      tool.status = error instanceof RunCancelledError ? 'cancelled' : 'failed';
    }
    activity.status = tool.status; activity.durationMs = Date.now() - activity.startedAt; recordActivity();
    observer.event({ type: 'tool_end', step: round, toolCallId: tool.call.id });
    // Cancellation never discards an operation that already committed successfully.
    await checkpoint();
  };
  if (sequential) {
    for (const tool of step.tools) {
      await prepare([tool]);
      await execute(tool);
      cancellation.check();
    }
  } else {
    await prepare(step.tools);
    // Drain every admitted operation and save before the run can finish, even on error.
    const errors = await Promise.all(step.tools.map(async (tool): Promise<Error | undefined> => {
      try { await execute(tool); return undefined; }
      catch (error) { return error as Error; }
    }));
    const failure = errors.find((error) => error !== undefined && !(error instanceof RunCancelledError)) ||
      errors.find((error) => error !== undefined);
    if (failure) { throw failure; }
    cancellation.check();
  }
}
