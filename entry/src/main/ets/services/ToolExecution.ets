import { Diagnostics } from '../model/Diagnostics';
import { AgentStep, ToolDefinition, ToolExecution, ToolExecutionMode, toolError } from '../model/Agent';
import { UsageToolActivity } from '../model/Usage';
import { AgentTools, LoopObserver } from './AgentLoop';
import { Cancellation, RunCancelledError } from './Cancellation';
import { ToolFailure, ToolResultError, parseToolArguments } from '../model/ToolFailure';
import { toolOutcome } from '../model/ToolOutcome';

export class ToolPersistenceError extends Error {}
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
    await observer.waitForExecution?.(cancellation);
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
    await observer.waitForExecution?.(cancellation);
    if (cancellation.cancelled) { tool.status = 'pending'; cancellation.check(); }
    observer.event({ type: 'tool_start', step: round, toolCallId: tool.call.id });
    if (cancellation.cancelled) { tool.status = 'pending'; cancellation.check(); }
    const diagnosticId = Diagnostics.nextId(); const diagnosticMark = Diagnostics.begin(diagnosticId);
    if (Diagnostics.recording) { Diagnostics.event('tool.start', { round: round, argumentChars: tool.call.function.arguments.length }, diagnosticId); }
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
    let partial = false;
    try {
      const args = parseToolArguments(tool.call.function.arguments);
      if (!args || typeof args !== 'object' || Array.isArray(args)) {
        throw new ToolFailure('INVALID_ARGUMENTS', 'Tool arguments must be a JSON object.', 'fix_arguments');
      }
      let output = await tools.execute(tool.call, cancellation, {
        execution: tool,
        executeChild: async (child, nestedTools, signal) => {
          const nestedStep: AgentStep = { content: '', tools: [child], usage: step.usage };
          try {
            await executeToolBatch(nestedStep, round, nestedTools, nestedTools.definitions(), signal, {
              checkpoint: checkpoint, toolActivity: observer.toolActivity, waitForExecution: observer.waitForExecution,
              refreshToolResult: observer.refreshToolResult,
              event: (event) => observer.event({ type: event.type, step: round, toolCallId: tool.call.id })
            });
          } catch (error) {
            if (error instanceof RunCancelledError) { throw error; }
            throw new ToolPersistenceError((error as Error).message);
          }
        }
      });
      // A stop while waiting must not discard an operation that already completed.
      if (!cancellation.cancelled) {
        try {
          await observer.waitForExecution?.(cancellation);
          if (!cancellation.cancelled && observer.refreshToolResult) { output = await observer.refreshToolResult(tool.call, output, cancellation); }
        } catch (error) {
          if (!(error instanceof RunCancelledError && cancellation.cancelled)) { throw error as Error; }
        }
      }
      const outcome = toolOutcome(output);
      partial = outcome.partial;
      tool.output = outcome.output;
      tool.status = outcome.failed ? 'failed' : 'complete';
    } catch (error) {
      if (error instanceof ToolPersistenceError) { throw error; }
      if (!cancellation.cancelled) { await observer.waitForExecution?.(cancellation); }
      tool.output = toolError(error as Error);
      tool.status = error instanceof RunCancelledError || (error instanceof ToolResultError && error.code === 'CANCELLED') ? 'cancelled' : 'failed';
    }
    if (tool.status === 'failed') {
      Diagnostics.log('warn', 'tool', 'failed', { operationId: diagnosticId, round: round, chars: tool.output.length });
    } else if (partial) {
      Diagnostics.log('info', 'tool', 'partial', { operationId: diagnosticId, round: round, chars: tool.output.length });
    }
    if (Diagnostics.recording) { Diagnostics.end('tool.execute', diagnosticMark, { failed: tool.status === 'failed' ? 1 : 0, cancelled: tool.status === 'cancelled' ? 1 : 0, outputChars: tool.output.length, round: round }); }
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
