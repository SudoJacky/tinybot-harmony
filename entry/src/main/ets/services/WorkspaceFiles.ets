import { Cancellation } from './Cancellation';

export interface WorkspaceEntry { name: string; kind: string; }
export interface WorkspaceListing { path: string; entries: WorkspaceEntry[]; truncated: boolean; }
export interface WorkspaceText { path: string; content: string; }
export interface WorkspaceWrite { path: string; bytes: number; written: boolean; }
export interface FileBaseline { path: string; existed: boolean; content: string; }

// Native storage and in-memory adapters share typed results. Tool dispatch owns JSON encoding.
export interface WorkspaceFiles {
  list(path: string, cancellation: Cancellation): Promise<WorkspaceListing>;
  read(path: string, cancellation: Cancellation): Promise<WorkspaceText>;
  write(path: string, content: string, cancellation: Cancellation): Promise<WorkspaceWrite>;
}
