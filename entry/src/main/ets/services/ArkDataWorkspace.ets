import { fileIo as fs } from '@kit.CoreFileKit';
import { threadWorkspacePath } from '../model/Workspace';
import { parseLifeBoard } from '../model/LifeBoard';
import { parsePanelRecord } from '../model/LifePanel';
import { ArkDataRecords } from './ArkDataRecords';
import { contentVersion } from './TextDigest';
import { withFileMutation } from './FileMutationQueue';

const MANAGED_PATH = /^(life-panels\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\/panel\.json|life-boards\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\/board\.json)$/;
const workspaces = new Map<string, () => Promise<ArkDataRecords>>();
export const WORKSPACE_DELETIONS = 'workspace-deletions';
interface WorkspaceDeletion { deleted: true; baseUpdatedAt: number; baseDigest: string; }
interface TimedRecord { updatedAt: number; }

function recordTime(path: string, text: string): number {
  const parts = path.split('/');
  return parts[0] === 'life-panels' ? parsePanelRecord(text, parts[1]).updatedAt : parseLifeBoard(text, parts[1]).updatedAt;
}

export function workspaceDeletion(text: string): WorkspaceDeletion | undefined {
  const value = JSON.parse(text) as WorkspaceDeletion;
  if (value?.deleted === undefined) { return undefined; }
  if (value.deleted !== true || !Number.isFinite(value.baseUpdatedAt) ||
    typeof value.baseDigest !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value.baseDigest)) {
    throw new Error('Invalid synchronized workspace deletion');
  }
  return value;
}

export function isManagedWorkspaceRecord(path: string): boolean { return MANAGED_PATH.test(path); }

export function registerWorkspaceDatabase(root: string, database: () => Promise<ArkDataRecords>): void {
  workspaces.set(root, database);
}

export function workspaceDatabase(root: string): (() => Promise<ArkDataRecords>) | undefined { return workspaces.get(root); }

export class ArkDataWorkspace {
  private database: () => Promise<ArkDataRecords>;
  private scope: string;
  private root: string;
  private id: string;
  private constructor(database: () => Promise<ArkDataRecords>, id: string, root: string) {
    this.database = database; this.scope = 'workspace:' + id; this.id = id; this.root = root;
  }
  static forRoot(root: string): ArkDataWorkspace | undefined {
    const split = root.lastIndexOf('/'), parent = root.slice(0, split);
    const database = workspaceDatabase(parent);
    if (!database) { return undefined; }
    const id = root.slice(split + 1);
    threadWorkspacePath(parent, id);
    return new ArkDataWorkspace(database, id, root);
  }
  async paths(): Promise<string[]> { return (await this.database()).ids(this.scope); }
  async read(path: string): Promise<string | undefined> { return (await this.database()).read(this.scope, path); }
  // Local callers hold the same file mutation lock as receive(). The deletion and
  // its base survive disabled sync, process exit, and failed transactions together.
  async write(path: string, text?: string): Promise<string | undefined> {
    const db = await this.database(), id = this.id + '/' + path;
    const current = await db.read(this.scope, path);
    let deletion: string | undefined;
    if (text === undefined) {
      if (current === undefined) { return; }
      const removed: WorkspaceDeletion = { deleted: true, baseUpdatedAt: recordTime(path, current), baseDigest: await contentVersion(current) };
      deletion = JSON.stringify(removed);
    } else if (text !== current) {
      const previous = await db.read(WORKSPACE_DELETIONS, id);
      const base = current === undefined ? (previous ? workspaceDeletion(previous)!.baseUpdatedAt : -Infinity) : recordTime(path, current);
      // Keep per-object revisions monotonic even after clock changes or restoration.
      if (recordTime(path, text) <= base) {
        const value = JSON.parse(text) as TimedRecord;
        value.updatedAt = base + 1; text = JSON.stringify(value);
      }
    }
    await db.commit([{ scope: this.scope, id: path, text: text }, { scope: WORKSPACE_DELETIONS, id: id, text: deletion }]);
    return text;
  }

  // Returns whether an edit won a concurrent delete. Stale snapshots never undo
  // a deletion; genuine subsequent edits keep their content on both devices.
  receive(path: string, text: string): Promise<boolean> {
    return withFileMutation(this.root + '/' + path, async () => {
      const db = await this.database(), id = this.id + '/' + path;
      const current = await db.read(this.scope, path), incoming = workspaceDeletion(text);
      const removedText = await db.read(WORKSPACE_DELETIONS, id);
      const removed = removedText === undefined ? undefined : workspaceDeletion(removedText);
      if (incoming) {
        if (current !== undefined) {
          // Wall-clock order does not prove ancestry: an independently edited
          // older revision must not be destroyed by another device's deletion.
          if (await contentVersion(current) !== incoming.baseDigest) { return true; }
        } else if (removed && removed.baseUpdatedAt >= incoming.baseUpdatedAt) { return false; }
        await db.commit([{ scope: this.scope, id: path }, { scope: WORKSPACE_DELETIONS, id: id, text: text }], 'peer');
        return false;
      }
      const time = recordTime(path, text);
      if (current === text || current !== undefined && recordTime(path, current) > time) { return false; }
      if (removed && (time < removed.baseUpdatedAt ||
        time === removed.baseUpdatedAt && await contentVersion(text) === removed.baseDigest)) { return false; }
      await db.commit([{ scope: this.scope, id: path, text: text }, { scope: WORKSPACE_DELETIONS, id: id }], 'peer');
      return removed !== undefined;
    });
  }
}

export async function legacyWorkspaceRecords(root: string, kind: string): Promise<string[]> {
  const directory = root + '/' + kind;
  if (!await fs.access(directory)) { return []; }
  const stat = await fs.lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error('Invalid managed workspace directory'); }
  const paths: string[] = [];
  for (const id of await fs.listFile(directory)) {
    const folder = threadWorkspacePath(directory, id), info = await fs.lstat(folder);
    if (!info.isDirectory() || info.isSymbolicLink()) { throw new Error('Invalid managed workspace record directory'); }
    const path = kind + '/' + id + (kind === 'life-boards' ? '/board.json' : '/panel.json');
    if (!await fs.access(root + '/' + path)) { continue; }
    const file = await fs.lstat(root + '/' + path);
    if (!isManagedWorkspaceRecord(path) || !file.isFile() || file.isSymbolicLink()) { throw new Error('Invalid managed workspace record'); }
    paths.push(path);
  }
  return paths;
}

export async function managedWorkspaceRecords(root: string, kind: string): Promise<string[]> {
  const ark = ArkDataWorkspace.forRoot(root);
  return ark ? (await ark.paths()).filter((path: string) => path.startsWith(kind + '/')) : legacyWorkspaceRecords(root, kind);
}
