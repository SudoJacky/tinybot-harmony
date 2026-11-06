import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { BoardEntry, LifeBoard, BoardItem, PanelReference, boardPath, boardLayoutKey, parseLifeBoard, referenceKey, validateReference } from '../model/LifeBoard';
import { GridRect, gridPlace, gridVacancy, validateGridRect } from '../model/PanelGrid';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { LifePanels } from './LifePanels';
import { Cancellation } from './Cancellation';
import { MiniAppStorage, MiniAppSnapshot } from '../model/MiniApp';
import { validatePanelViewState } from '../model/LifePanel';
import { withFileMutation } from './FileMutationQueue';
import { PanelChanges } from './PanelChanges';
import { withWorkspaceLifecycle } from './WorkspaceRetention';
export class LifeBoards {
  private workspaces: WorkspaceStore;
  private panels: LifePanels;
  constructor(filesDir: string) { this.workspaces = new WorkspaceStore(filesDir); this.panels = new LifePanels(filesDir); }
  async get(workspaceId: string, id: string): Promise<LifeBoard> {
    return parseLifeBoard((await new NativeWorkspaceFiles(this.workspaces.pathFor(workspaceId)).read(boardPath(id), new Cancellation())).content, id);
  }
  async save(workspaceId: string, id: string, title: string, description: string, items?: BoardItem[], archive?: boolean): Promise<LifeBoard> {
    if (items !== undefined) {
      if (!Array.isArray(items) || items.length > 100) { throw new Error('Invalid board items'); }
      items.forEach((item: BoardItem) => {
        validateReference(item); validateGridRect(item);
        if (Object.keys(item).some((key: string) => !['workspaceId', 'panelId', 'x', 'y', 'w', 'h', 'mountId', 'viewState'].includes(key))) { throw new Error('Invalid board item fields'); }
      });
    }
    const nextId = id || 'board-' + util.generateRandomUUID();
    return this.change(workspaceId, nextId, !id, async (before?: LifeBoard): Promise<LifeBoard> => ({ version: 2, id: nextId,
      editorThreadId: before?.editorThreadId, title: title.trim(), description: description.trim(), items: items === undefined ? before?.items || [] : items.map((item: BoardItem): BoardItem => {
        const saved = before?.items.find((old: BoardItem) => referenceKey(old) === referenceKey(item));
        return { workspaceId: item.workspaceId, panelId: item.panelId, x: item.x, y: item.y, w: item.w, h: item.h,
          mountId: saved?.mountId || 'mount-' + util.generateRandomUUID(), viewState: saved?.viewState };
      }),
      archived: archive === undefined ? before?.archived || false : archive, createdAt: before?.createdAt || Date.now(), updatedAt: Date.now() }));
  }
  private async change(workspaceId: string, id: string, create: boolean, operation: (board?: LifeBoard) => Promise<LifeBoard>): Promise<LifeBoard> {
    const root = this.workspaces.pathFor(workspaceId), files = new NativeWorkspaceFiles(root);
    return withWorkspaceLifecycle(root, () => withFileMutation(root + ':board:' + id, async (): Promise<LifeBoard> => {
      await this.workspaces.requireWorkspace(workspaceId);
      const path = boardPath(id), cancellation = new Cancellation();
      const old = create ? undefined : await files.read(path, cancellation), before = old ? parseLifeBoard(old.content, id) : undefined;
      const board = await operation(before); board.updatedAt = Date.now();
      parseLifeBoard(JSON.stringify(board), id);
      for (const item of board.items) { await this.panels.repository(item.workspaceId).get(item.panelId); }
      await files.writeLifeBoard(path, JSON.stringify(board), cancellation, { version: old?.version || null }); PanelChanges.emit(); return board;
    }));
  }
  async setEditor(workspaceId: string, id: string, threadId: string): Promise<void> {
    await this.change(workspaceId, id, false, async (previous?: LifeBoard): Promise<LifeBoard> => { previous!.editorThreadId = threadId; return previous!; });
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
        const rect = gridVacancy(items);
        items.push({ workspaceId: reference.workspaceId, panelId: reference.panelId, mountId: 'mount-' + util.generateRandomUUID(), x: rect.x, y: rect.y, w: rect.w, h: rect.h });
      }
      before.items = items; return before;
    });
  }
  async place(workspaceId: string, id: string, reference: PanelReference, target: GridRect, expectedLayout: string): Promise<LifeBoard> {
    validateReference(reference);
    return this.change(workspaceId, id, false, async (previous?: LifeBoard): Promise<LifeBoard> => {
      const board = previous!;
      if (board.archived) { throw new Error('Restore the board before placing a card'); }
      if (boardLayoutKey(board.items) !== expectedLayout) { throw new Error('Board layout changed; reload before moving the card'); }
      let index = board.items.findIndex((item: BoardItem) => referenceKey(item) === referenceKey(reference));
      if (index < 0) {
        const panel = await this.panels.repository(reference.workspaceId).get(reference.panelId);
        if (panel.archived) { throw new Error('Restore the card before placing it'); }
        index = board.items.length;
        board.items.push({ workspaceId: reference.workspaceId, panelId: reference.panelId, mountId: 'mount-' + util.generateRandomUUID(), x: target.x, y: target.y, w: target.w, h: target.h });
      }
      const rects = gridPlace(board.items, index, target);
      board.items = board.items.map((item: BoardItem, i: number): BoardItem => ({ workspaceId: item.workspaceId, panelId: item.panelId, mountId: item.mountId, viewState: item.viewState,
        x: rects[i].x, y: rects[i].y, w: rects[i].w, h: rects[i].h }));
      return board;
    });
  }
  binding(workspaceId: string, id: string, mountId: string): MiniAppStorage {
    return new BoardViewStorage(this, workspaceId, id, mountId);
  }
  async saveViewState(workspaceId: string, id: string, mountId: string, value: Object | null, revision: string): Promise<MiniAppSnapshot> {
    const snapshot: MiniAppSnapshot = { value: value, revision: util.generateRandomUUID() };
    validatePanelViewState(snapshot);
    await this.change(workspaceId, id, false, async (previous?: LifeBoard): Promise<LifeBoard> => {
      const item = previous!.items.find((item: BoardItem) => item.mountId === mountId);
      if (!item || previous!.archived) { throw new Error('Board placement is unavailable'); }
      const panel = await this.panels.repository(item.workspaceId).get(item.panelId);
      if (panel.archived) { throw new Error('Card is archived'); }
      if ((item.viewState?.revision || 'initial') !== revision) { throw new Error('View state changed; reload before saving'); }
      item.viewState = snapshot; return previous!;
    });
    return snapshot;
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
    // Changing a card or a board description must not shuffle the tab strip.
    return entries.sort((a: BoardEntry, b: BoardEntry) => a.board.createdAt - b.board.createdAt || a.board.id.localeCompare(b.board.id));
  }
}

class BoardViewStorage implements MiniAppStorage {
  private boards: LifeBoards;
  private workspaceId: string;
  private id: string;
  private mountId: string;
  constructor(boards: LifeBoards, workspaceId: string, id: string, mountId: string) {
    this.boards = boards; this.workspaceId = workspaceId; this.id = id; this.mountId = mountId;
  }
  async load(): Promise<MiniAppSnapshot> {
    const board = await this.boards.get(this.workspaceId, this.id);
    const item = board.items.find((item: BoardItem) => item.mountId === this.mountId);
    if (!item) { throw new Error('Board placement is unavailable'); }
    return item.viewState || { value: null, revision: 'initial' };
  }
  save(value: Object | null, revision: string): Promise<MiniAppSnapshot> {
    return this.boards.saveViewState(this.workspaceId, this.id, this.mountId, value, revision);
  }
}
