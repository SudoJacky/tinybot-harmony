import { FileDiff } from './FileDiff';
import { AgentStep, ToolExecution } from './Agent';

export interface TurnFileChange { order: number; diff: FileDiff; }

// Receipts keep the net change as of that commit. Use commit order, not parallel call order.
export function turnFileChanges(steps: AgentStep[]): FileDiff[] {
  const latest = new Map<string, TurnFileChange>();
  const visit = (tool: ToolExecution): void => {
    if (tool.status === 'complete' && tool.turnFileChange) {
      const change = tool.turnFileChange;
      if (!latest.has(change.diff.path) || latest.get(change.diff.path)!.order < change.order) { latest.set(change.diff.path, change); }
    }
    (tool.children || []).forEach(visit);
  };
  steps.forEach((step: AgentStep) => step.tools.forEach(visit));
  return Array.from(latest.values()).map((change: TurnFileChange) => change.diff)
    .filter((diff: FileDiff) => diff.created || diff.added > 0 || diff.removed > 0)
    .sort((a: FileDiff, b: FileDiff) => a.path.localeCompare(b.path));
}
