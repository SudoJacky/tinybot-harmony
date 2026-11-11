import { fileIo as fs } from '@kit.CoreFileKit';
import { threadWorkspacePath } from '../model/Workspace';
import { ArkDataRecords } from './ArkDataRecords';

const MANAGED_PATH = /^(life-panels\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\/panel\.json|life-boards\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\/board\.json)$/;
const workspaces = new Map<string, () => Promise<ArkDataRecords>>();

export function isManagedWorkspaceRecord(path: string): boolean { return MANAGED_PATH.test(path); }

export function registerWorkspaceDatabase(root: string, database: () => Promise<ArkDataRecords>): void {
  workspaces.set(root, database);
}

export function workspaceDatabase(root: string): (() => Promise<ArkDataRecords>) | undefined { return workspaces.get(root); }

export class ArkDataWorkspace {
  private database: () => Promise<ArkDataRecords>;
  private scope: string;
  private constructor(database: () => Promise<ArkDataRecords>, id: string) {
    this.database = database; this.scope = 'workspace:' + id;
  }
  static forRoot(root: string): ArkDataWorkspace | undefined {
    const split = root.lastIndexOf('/'), parent = root.slice(0, split);
    const database = workspaceDatabase(parent);
    if (!database) { return undefined; }
    const id = root.slice(split + 1);
    threadWorkspacePath(parent, id);
    return new ArkDataWorkspace(database, id);
  }
  async paths(): Promise<string[]> { return (await this.database()).ids(this.scope); }
  async read(path: string): Promise<string | undefined> { return (await this.database()).read(this.scope, path); }
  async write(path: string, text?: string): Promise<void> {
    await (await this.database()).commit([{ scope: this.scope, id: path, text: text }]);
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
