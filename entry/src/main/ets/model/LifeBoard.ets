import { panelId } from './LifePanel';
import { threadWorkspacePath } from './Workspace';
import { GridRect, gridHeight, gridOverlap, validateGridRect } from './PanelGrid';
export interface PanelReference { workspaceId: string; panelId: string; }
export interface BoardItem extends PanelReference, GridRect {}
interface LegacyBoardItem extends PanelReference { size: string; height?: number; }
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
  if (!board || Object.keys(board).some((key: string) => !['version', 'id', 'title', 'description', 'items', 'archived', 'createdAt', 'updatedAt', 'editorThreadId'].includes(key)) || ![1, 2].includes(board.version) || board.id !== panelId(id) || typeof board.title !== 'string' || !board.title.trim() || board.title.length > 80 ||
    typeof board.description !== 'string' || board.description.length > 500 || !Array.isArray(board.items) || board.items.length > 100 ||
    typeof board.archived !== 'boolean' || !Number.isFinite(board.createdAt) || !Number.isFinite(board.updatedAt) || board.createdAt < 0 || board.updatedAt < 0) { throw new Error('Invalid Life Panel board'); }
  if (board.editorThreadId !== undefined && (typeof board.editorThreadId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(board.editorThreadId))) { throw new Error('Invalid board editor thread'); }
  if (board.version === 1) {
    const bottoms: number[] = [0, 0];
    board.items = (board.items as Object as LegacyBoardItem[]).map((item: LegacyBoardItem): BoardItem => {
      validateReference(item);
      if (Object.keys(item).some((key: string) => !['workspaceId', 'panelId', 'size', 'height'].includes(key)) || !['S', 'M', 'L'].includes(item.size) ||
        (item.height !== undefined && (!Number.isInteger(item.height) || item.height < 200 || item.height > 800))) { throw new Error('Invalid legacy board item'); }
      const w = item.size === 'S' ? 6 : 12, column = w === 12 || bottoms[0] <= bottoms[1] ? 0 : 1;
      const y = w === 12 ? Math.max(...bottoms) : bottoms[column], h = gridHeight(item.height || 240);
      bottoms[column] = y + h; if (w === 12) { bottoms[1] = y + h; }
      return { workspaceId: item.workspaceId, panelId: item.panelId, x: column * 6, y: y, w: w, h: h };
    });
    board.version = 2;
  }
  const seen: Set<string> = new Set<string>();
  board.items.forEach((item: BoardItem) => {
    validateReference(item);
    if (Object.keys(item).some((key: string) => !['workspaceId', 'panelId', 'x', 'y', 'w', 'h'].includes(key))) { throw new Error('Invalid board item fields'); }
    validateGridRect(item);
    if (seen.has(referenceKey(item))) { throw new Error('Duplicate board card'); } seen.add(referenceKey(item));
  });
  for (let i = 0; i < board.items.length; i++) {
    for (let j = i + 1; j < board.items.length; j++) {
      if (gridOverlap(board.items[i], board.items[j])) { throw new Error('Board cards overlap'); }
    }
  }
  return board;
}
export function boardLayoutKey(items: BoardItem[]): string {
  return JSON.stringify(items.map((item: BoardItem) => referenceKey(item) + ':' + [item.x, item.y, item.w, item.h].join(',')));
}
export function parsePanelTarget(value: string): PanelTarget {
  const target = JSON.parse(value) as PanelTarget;
  if (!target || typeof target.workspaceId !== 'string' || (target.panelId === undefined) === (target.boardId === undefined)) { throw new Error('Invalid Life Panel link'); }
  threadWorkspacePath('/workspace', target.workspaceId); panelId(target.panelId || target.boardId!); return target;
}
