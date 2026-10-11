import { Cancellation } from './Cancellation';
import { TextEdit } from '../model/WorkspaceEdit';

export interface WorkspaceEntry { name: string; kind: string; }
export interface WorkspaceListing { path: string; entries: WorkspaceEntry[]; truncated: boolean; }
export interface WorkspaceText { path: string; content: string; version: string; }
// null means create only; omitted guard is reserved for explicit user operations.
export interface WorkspaceWriteGuard { version: string | null; }
export interface WorkspaceWrite {
  path: string; bytes: number; written: boolean;
  // Local write receipt metadata; WorkspaceTools excludes it from the model result.
  before?: string; after?: string; created?: boolean; version: string;
}
export interface FileBaseline { path: string; existed: boolean; content: string; }

// Native storage and in-memory adapters share typed results. Tool dispatch owns JSON encoding.
export interface WorkspaceFiles {
  list(path: string, cancellation: Cancellation): Promise<WorkspaceListing>;
  read(path: string, cancellation: Cancellation): Promise<WorkspaceText>;
  write(path: string, content: string, cancellation: Cancellation, guard?: WorkspaceWriteGuard): Promise<WorkspaceWrite>;
  edit(path: string, edits: TextEdit[], version: string, cancellation: Cancellation): Promise<WorkspaceWrite>;
}
