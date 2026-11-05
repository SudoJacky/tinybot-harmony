import { panelId } from './LifePanel';
import { threadWorkspacePath } from './Workspace';
export interface PanelReference { workspaceId: string; panelId: string; }
export interface BoardItem extends PanelReference { size: string; height?: number; }
export interface LifeBoard {
  version: number; id: string; title: string; description: string; items: BoardItem[];
  editorThreadId?: string; archived: boolean; createdAt: number; updatedAt: number;
}
export interface BoardEntry { workspaceId: string; board: LifeBoard; }
export interface PanelTarget { workspaceId: string; panelId?: string; boardId?: string; request?: number; }
export function referenceKey(reference: PanelReference): string { return reference.workspaceId + '/' + reference.panelId; }
export function validateReference(reference: PanelReference): void {
  if (!reference || typeof reference.workspaceId !== 'string') { throw new Error('Invalid panel workspace'); }
  threadWorkspacePath('/workspace', reference.workspaceId); panelId(reference.panelId);
}
export function boardPath(id: string): string { return 'life-boards/' + panelId(id) + '/board.json'; }
export function parseLifeBoard(content: string, id: string): LifeBoard {
  const board = JSON.parse(content) as LifeBoard;
  if (!board || Object.keys(board).some((key: string) => !['version', 'id', 'title', 'description', 'items', 'archived', 'createdAt', 'updatedAt', 'editorThreadId'].includes(key)) || board.version !== 1 || board.id !== panelId(id) || typeof board.title !== 'string' || !board.title.trim() || board.title.length > 80 ||
    typeof board.description !== 'string' || board.description.length > 500 || !Array.isArray(board.items) || board.items.length > 100 ||
    typeof board.archived !== 'boolean' || !Number.isFinite(board.createdAt) || !Number.isFinite(board.updatedAt) || board.createdAt < 0 || board.updatedAt < 0) { throw new Error('Invalid Life Panel board'); }
  if (board.editorThreadId !== undefined && (typeof board.editorThreadId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(board.editorThreadId))) { throw new Error('Invalid board editor thread'); }
  const seen: Set<string> = new Set<string>();
  board.items.forEach((item: BoardItem) => {
    validateReference(item);
    if (Object.keys(item).some((key: string) => !['workspaceId', 'panelId', 'size', 'height'].includes(key))) { throw new Error('Invalid board item fields'); }
    if (item.height !== undefined && (!Number.isInteger(item.height) || item.height < 200 || item.height > 800)) { throw new Error('Card height must be 200–800'); }
    if (!['S', 'M', 'L'].includes(item.size) || seen.has(referenceKey(item))) { throw new Error('Invalid or duplicate board card'); } seen.add(referenceKey(item));
  }); return board;
}
export function parsePanelTarget(value: string): PanelTarget {
  const target = JSON.parse(value) as PanelTarget;
  if (!target || typeof target.workspaceId !== 'string' || (target.panelId === undefined) === (target.boardId === undefined)) { throw new Error('Invalid Life Panel link'); }
  threadWorkspacePath('/workspace', target.workspaceId); panelId(target.panelId || target.boardId!); return target;
}
