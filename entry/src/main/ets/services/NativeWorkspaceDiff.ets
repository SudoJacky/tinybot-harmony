import { taskpool } from '@kit.ArkTS';
import { WorkspaceDiffs, workspaceDiffs } from '../model/WorkspaceDiff';

@Concurrent
function computeWorkspaceDiffs(path: string, before: string, after: string, baseline: string,
  created: boolean, baselineCreated: boolean): WorkspaceDiffs {
  return workspaceDiffs(path, before, after, baseline, created, baselineCreated);
}

export async function nativeWorkspaceDiffs(path: string, before: string, after: string, baseline: string,
  created: boolean, baselineCreated: boolean): Promise<WorkspaceDiffs> {
  return await taskpool.execute(computeWorkspaceDiffs, path, before, after, baseline, created, baselineCreated) as WorkspaceDiffs;
}
