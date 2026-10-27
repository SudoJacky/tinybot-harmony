import { FileDiff, fileDiff } from './FileDiff';

export interface WorkspaceDiffs { current: FileDiff; cumulative: FileDiff; }
export type WorkspaceDiffComputer = (path: string, before: string, after: string, baseline: string,
  created: boolean, baselineCreated: boolean) => Promise<WorkspaceDiffs>;

export function workspaceDiffs(path: string, before: string, after: string, baseline: string,
  created: boolean, baselineCreated: boolean): WorkspaceDiffs {
  const current = fileDiff(path, before, after, created);
  return { current: current, cumulative: before === baseline && created === baselineCreated ? current :
    fileDiff(path, baseline, after, baselineCreated) };
}
