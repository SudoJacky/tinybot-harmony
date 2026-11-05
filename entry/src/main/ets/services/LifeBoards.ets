import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { BoardEntry, LifeBoard, BoardItem, PanelReference, boardPath, parseLifeBoard, referenceKey, validateReference } from '../model/LifeBoard';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { LifePanels } from './LifePanels';
import { Cancellation } from './Cancellation';
import { withFileMutation } from './FileMutationQueue';
import { PanelChanges } from './PanelChanges';
export class LifeBoards {
  private workspaces: WorkspaceStore;
  private panels: LifePanels;
  constructor(filesDir: string) { this.workspaces = new WorkspaceStore(filesDir); this.panels = new LifePanels(filesDir); }
  async get(workspaceId: string, id: string): Promise<LifeBoard> {
    return parseLifeBoard((await new NativeWorkspaceFiles(this.workspaces.pathFor(workspaceId)).read(boardPath(id), new Cancellation())).content, id);
  }
  async save(workspaceId: string, id: string, title: string, description: string, items?: BoardItem[], archive?: boolean): Promise<LifeBoard> {
    const nextId = id || 'board-' + util.generateRandomUUID();
    return this.change(workspaceId, nextId, !id, async (before?: LifeBoard): Promise<LifeBoard> => ({ version: 1, id: nextId,
      title: title.trim(), description: description.trim(), items: items === undefined ? before?.items || [] : items,
      archived: archive === undefined ? before?.archived || false : archive, createdAt: before?.createdAt || Date.now(), updatedAt: Date.now() }));
  }
  private async change(workspaceId: string, id: string, create: boolean, operation: (board?: LifeBoard) => Promise<LifeBoard>): Promise<LifeBoard> {
    await this.workspaces.requireWorkspace(workspaceId);
    const root = this.workspaces.pathFor(workspaceId), files = new NativeWorkspaceFiles(root);
    return withFileMutation(root + ':board:' + id, async (): Promise<LifeBoard> => {
      const path = boardPath(id), cancellation = new Cancellation();
      const old = create ? undefined : await files.read(path, cancellation), before = old ? parseLifeBoard(old.content, id) : undefined;
      const board = await operation(before); board.updatedAt = Date.now();
      parseLifeBoard(JSON.stringify(board), id);
      for (const item of board.items) { await this.panels.repository(item.workspaceId).get(item.panelId); }
      await files.writeLifeBoard(path, JSON.stringify(board), cancellation, { version: old?.version || null }); PanelChanges.emit(); return board;
    });
  }
  async pin(workspaceId: string, id: string, reference: PanelReference, present: boolean): Promise<LifeBoard> {
    validateReference(reference);
    return this.change(workspaceId, id, false, async (previous?: LifeBoard): Promise<LifeBoard> => {
      const before = previous!, items = before.items.filter((item: BoardItem) => referenceKey(item) !== referenceKey(reference));
      if (present) {
        if (before.archived) { throw new Error('Restore the board before pinning a card'); }
        const panel = await this.panels.repository(reference.workspaceId).get(reference.panelId);
        if (panel.archived) { throw new Error('Restore the card before pinning it'); }
        const existing = before.items.find((item: BoardItem) => referenceKey(item) === referenceKey(reference));
        if (existing) { return before; }
        items.push({ workspaceId: reference.workspaceId, panelId: reference.panelId, size: panel.definition.size });
      }
      before.items = items; return before;
    });
  }
  async arrange(workspaceId: string, id: string, reference: PanelReference, beforeKey: string, size?: string): Promise<LifeBoard> {
    return this.change(workspaceId, id, false, async (previous?: LifeBoard): Promise<LifeBoard> => {
      const board = previous!, item = board.items.find((item: BoardItem) => referenceKey(item) === referenceKey(reference));
      if (!item) { throw new Error('Card no longer belongs to this board'); }
      if (size) { item.size = size; }
      const items = board.items.filter((entry: BoardItem) => referenceKey(entry) !== referenceKey(reference));
      const target = beforeKey ? items.findIndex((entry: BoardItem) => referenceKey(entry) === beforeKey) : items.length;
      if (target < 0) { throw new Error('Drop target changed; reload the board'); } items.splice(target, 0, item);
      board.items = items; return board;
    });
  }
  async list(): Promise<BoardEntry[]> {
    const entries: BoardEntry[] = [];
    if (!await fs.access(this.workspaces.rootDir)) { return entries; }
    for (const workspaceId of await fs.listFile(this.workspaces.rootDir)) {
      await this.workspaces.requireWorkspace(workspaceId);
      const directory = this.workspaces.pathFor(workspaceId) + '/life-boards';
      if (!await fs.access(directory)) { continue; }
      const stat = await fs.lstat(directory); if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error('Invalid Life Panel board directory'); }
      for (const id of await fs.listFile(directory)) {
        if (!await fs.access(directory + '/' + id + '/board.json')) { continue; }
        entries.push({ workspaceId: workspaceId, board: await this.get(workspaceId, id) });
      }
    }
    return entries.sort((a: BoardEntry, b: BoardEntry) => b.board.updatedAt - a.board.updatedAt);
  }
}
