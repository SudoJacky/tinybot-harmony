import { PanelInputs } from '../model/PanelContract';
import { PanelRect, panelMasonry, panelSourceLabel, panelRunLabel, panelErrorText } from '../model/PanelPresentation';
import { GridRect, GRID_GAP, GRID_ROW_STEP, GRID_MAX_ROWS, gridStep, gridPixels, gridSnap, gridPlace, gridVacancy } from '../model/PanelGrid';
import { PanelGridGuide } from './PanelGridGuide';
import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Motion, relativeTime, gradientColor } from '../common/Theme';
import { Banner, IconButton } from '../common/Widgets';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';
import { PanelEntry } from '../model/LifePanel';
import { LifePanels } from '../services/LifePanels';
import { Cancellation, RunCancelledError } from '../services/Cancellation';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { LifePanelCard } from './LifePanelCard';
import { PanelConnectionPanel } from './PanelConnectionPanel';
import { PanelTaskPanel } from './PanelTaskPanel';
import { LifeBoards } from '../services/LifeBoards';
import { PanelChanges } from '../services/PanelChanges';
import { BoardEntry, BoardItem, boardLayoutKey, boardLayoutItems, PanelTarget, parsePanelTarget, referenceKey } from '../model/LifeBoard';
import { PanelRecord, PanelRun } from '../model/LifePanel';
import { MiniAppStorage } from '../model/MiniApp';
import { builtinWidget } from '../model/BuiltinWidgets';
import { BuiltinWidgets } from '../services/BuiltinWidgets';
import { ProviderBalanceSource } from '../services/ProviderBalanceSource';
import { BuiltinWidgetGallery } from './BuiltinWidgetGallery';
import { BuiltinBoard } from '../services/BuiltinBoard';

interface PanelEditTarget { workspaceId: string; panelId: string; configRevision: number; runtimeError?: string; sourceError: string; }
interface BoardGridContext { columns: number; columnWidth: number; rowHeight: number; gap: number; minW: number; maxW: number; minH: number; maxH: number; defaultW: number; defaultH: number; }
@Component
export struct LifePanelsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('activityChanged') private foreground: boolean = true;
  @State @Watch('activityChanged') private active: boolean = false;
  @Prop @Watch('targetChanged') requestedTarget: string = '';
  @ObjectLink app: ChatViewModel;
  onChat: () => void = () => {};
  onShown: () => void = () => {};
  @State private entries: PanelEntry[] = [];
  @State private boards: BoardEntry[] = [];
  @State @Watch('revealBoard') private boardSelection: string = '';
  @State private sheetOpen: boolean = false;
  @State private sheetKind: string = '';
  @State private boardEditorId: string = '';
  @State private boardEditorWorkspace: string = '';
  @State private boardTitle: string = '';
  @State private boardDescription: string = '';
  @State private pinEntry: PanelEntry | undefined = undefined;
  @State private taskEntry: PanelEntry | undefined = undefined;
  @State private dragging: string = '';
  @State private dragX: number = 0;
  @State private dragY: number = 0;
  @State private boardWidth: number = 360;
  @State private now: number = Date.now();
  @State private error: string = '';
  @State private pending: string[] = [];
  @State @Watch('detailChanged') private selected: string = '';
  @State private removed: boolean = false;
  @State private creating: boolean = false;
  @State private addingBuiltin: string = '';
  @State private connectionEntry: PanelEntry | undefined = undefined;
  @State private refreshing: boolean = false;
  @State private cardHeights: Record<string, number> = {};
  @State private connectionStatus: string = '';
  @State private editingPrompt: boolean = false;
  @State private prompt: string = '';
  @State private editTarget: string = '';
  @State private resizing: string = '';
  @State private resizeHeight: number = 0;
  @State private detailHeight: number = 500;
  @State private feedback: string = '';
  @State private cardQuery: string = '';
  @State private resizeWidth: number = 0;
  @State private layoutSaving: boolean = false;
  @State private boardSaving: boolean = false;
  @State private editorThreadId: string = '';
  @State private previewRects: GridRect[] = [];
  @State private targetRect: GridRect = { x: 0, y: 0, w: 2, h: 2 };
  @State private viewportHeight: number = 500;
  @State private scrollOffset: number = 0;
  private dragOrigin: PanelRect = { x: 0, y: 0, width: 0, height: 0 };
  private gestureRect: GridRect = { x: 0, y: 0, w: 2, h: 2 };
  private gestureItems: BoardItem[] = [];
  private gestureLayout: string = '';
  private gestureBoard: string = '';
  private gestureScroll: number = 0;
  private gestureExtent: number = 0;
  private dragTouchX: number = 0;
  private dragTouchY: number = 0;
  private pointerX: number = 0;
  private pointerY: number = 0;
  private viewportTop: number = 0;
  private edgeTimer: number = -1;
  private contentScroller: Scroller = new Scroller();
  private boardScroller: Scroller = new Scroller();
  private store?: LifePanels;
  private mounted: boolean = false;
  private timer: number = -1;
  private cancellation: Cancellation = new Cancellation();
  private scanning: boolean = false;
  private unsubscribe?: () => void;
  private lastTarget: string = '';
  private guidesPrepared: boolean = false;
  private boardStore(): LifeBoards { return new LifeBoards((this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir); }
  private boardKey(entry: BoardEntry): string { return entry.workspaceId + '/' + entry.board.id; }
  private boardFor(key: string): BoardEntry { return this.boards.find((entry: BoardEntry) => this.boardKey(entry) === key)!; }
  private currentBoard(): BoardEntry | undefined { return this.boards.find((entry: BoardEntry) => this.boardKey(entry) === this.boardSelection); }
  private currentEditorThreadId(): string {
    const board = this.currentBoard();
    return board ? board.board.editorThreadId || '' : this.editorThreadId;
  }
  private panels(): LifePanels {
    if (!this.store) { this.store = new LifePanels((this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir); }
    return this.store;
  }
  aboutToAppear(): void { this.mounted = true; this.activityChanged(); this.unsubscribe = PanelChanges.subscribe(() => {
    // Initial publication emits changes before the guide board exists. The first scan reloads
    // the completed installation; a partial snapshot must not clear its default selection.
    if (this.mounted && this.active && this.guidesPrepared) { this.reload().catch((error: Error) => this.report(error)); }
  }); }
  aboutToDisappear(): void { this.mounted = false; this.stop(); this.unsubscribe?.(); }
  private stop(): void { this.resetGesture(); clearTimeout(this.timer); this.timer = -1; this.cancellation.cancel(); }
  private activityChanged(): void {
    this.stop();
    if (!this.mounted || !this.foreground || !this.active) { return; }
    this.cancellation = new Cancellation(); this.scan();
  }
  private async reload(): Promise<void> {
    const entries = await this.panels().list();
    const boards = await this.boardStore().list();
    for (const item of boards.flatMap((entry: BoardEntry) => entry.board.items)) { if (!entries.some((entry: PanelEntry) => this.entryKey(entry) === referenceKey(item))) { throw new Error('A board references a missing card: ' + item.panelId); } }
    if (this.mounted) {
      this.entries = entries; this.boards = boards;
      if (this.boardSelection && !boards.some((entry: BoardEntry) => this.boardKey(entry) === this.boardSelection && !entry.board.archived)) { this.boardSelection = ''; this.selected = ''; }
      this.now = Date.now(); this.targetChanged();
    }
  }
  private targetChanged(): void {
    if (!this.mounted || !this.requestedTarget || this.lastTarget === this.requestedTarget || !this.entries.length && !this.boards.length) { return; }
    try {
      const target = parsePanelTarget(this.requestedTarget);
      if (target.panelId) {
        const entry = this.entries.find((entry: PanelEntry) => this.entryKey(entry) === target.workspaceId + '/' + target.panelId);
        if (!entry) { throw new Error('Linked card is unavailable'); } this.boardSelection = ''; this.removed = entry.panel.archived; this.selected = this.entryKey(entry);
      } else {
        const entry = this.boards.find((entry: BoardEntry) => this.boardKey(entry) === target.workspaceId + '/' + target.boardId);
        if (!entry || entry.board.archived) { throw new Error('Linked board is unavailable or archived'); } this.boardSelection = this.boardKey(entry); this.selected = ''; this.removed = false;
      }
      this.lastTarget = this.requestedTarget;
    } catch (error) { this.lastTarget = this.requestedTarget; this.report(error as Error); }
  }
  private report(error: Error): void {
    if (this.mounted) { this.error = error.message; }
    Diagnostics.log('error', 'life-panel', 'action_failed', {}, error);
  }
  private scan(): void {
    if (this.scanning) {
      this.timer = setTimeout(() => this.scan(), 1000); return;
    }
    this.scanning = true;
    const signal = this.cancellation;
    // The app-level scheduler owns automatic work so navigating away cannot cancel it.
    this.prepareGuides(signal).then(() => this.reload()).catch((error: Error) => { if (!signal.cancelled) { this.report(error); } }).finally(() => {
      this.scanning = false;
      if (this.mounted && this.foreground && this.active && !signal.cancelled) { this.timer = setTimeout(() => this.scan(), 30000); }
    });
  }
  private async prepareGuides(signal: Cancellation): Promise<void> {
    if (this.guidesPrepared) { return; }
    const target = await new BuiltinBoard(this.getUIContext().getHostContext() as common.UIAbilityContext).prepare(signal);
    signal.check(); this.guidesPrepared = true;
    if (target && !this.boardSelection && !this.requestedTarget) { this.boardSelection = target.workspaceId + '/' + target.boardId; this.selected = ''; }
  }
  private entryKey(entry: PanelEntry): string { return entry.workspaceId + '/' + entry.panel.id; }
  private visible(): PanelEntry[] {
    const entries = this.entries.filter((entry: PanelEntry) => entry.panel.archived === this.removed), board = this.currentBoard();
    if (!board) { return entries; }
    return board.board.items.flatMap((item) => entries.filter((entry: PanelEntry) => this.entryKey(entry) === referenceKey(item)));
  }
  private gridRect(key: string): GridRect {
    const index = this.gestureItems.findIndex((item: BoardItem) => referenceKey(item) === key);
    if (this.previewRects.length && index >= 0) { return this.previewRects[index]; }
    return this.currentBoard()!.board.items.find((item: BoardItem) => referenceKey(item) === key)!;
  }
  private heightOnBoard(entry: PanelEntry): number {
    return this.currentBoard() ? (this.resizing === this.entryKey(entry) ? this.resizeHeight : this.rect(this.entryKey(entry)).height) : 0;
  }
  private resetGesture(): void {
    clearTimeout(this.edgeTimer); this.edgeTimer = -1;
    this.dragging = ''; this.resizing = ''; this.dragX = 0; this.dragY = 0;
    this.previewRects = []; this.gestureItems = []; this.resizeWidth = 0;
  }
  private beginLayout(key: string, event: GestureEvent, resize: boolean): void {
    const board = this.currentBoard(), finger = event.fingerList.find((point: FingerInfo) => !!point);
    if (!board || !finger || this.layoutSaving || this.dragging || this.resizing) { return; }
    this.gestureItems = board.board.items;
    this.gestureLayout = boardLayoutKey(board.board.items); this.gestureBoard = this.boardKey(board);
    this.gestureRect = this.gridRect(key); this.targetRect = this.gestureRect;
    this.dragOrigin = gridPixels(this.gestureRect, this.boardWidth);
    this.gestureExtent = this.boardHeight(); this.gestureScroll = this.contentScroller.currentOffset().yOffset;
    this.dragTouchX = finger.globalX - (resize ? event.offsetX : 0);
    this.dragTouchY = finger.globalY - (resize ? event.offsetY : 0);
    this.pointerX = finger.globalX; this.pointerY = finger.globalY;
    if (resize) { this.resizing = key; } else { this.dragging = key; }
    this.updateLayout(); this.followEdge();
  }
  private startMove(key: string, event: GestureEvent): void { this.beginLayout(key, event, false); }
  private moveCard(event: GestureEvent): void {
    if ((!this.dragging && !this.resizing) || this.layoutSaving) { return; }
    const finger = event.fingerList.find((point: FingerInfo) => !!point); if (!finger) { return; }
    this.pointerX = finger.globalX; this.pointerY = finger.globalY; this.updateLayout(); this.followEdge();
  }
  private updateLayout(): void {
    if (this.gestureBoard !== this.boardSelection || this.layoutSaving) { return; }
    this.dragX = this.pointerX - this.dragTouchX;
    this.dragY = this.pointerY - this.dragTouchY + this.contentScroller.currentOffset().yOffset - this.gestureScroll;
    const target = gridSnap(this.gestureRect, this.dragX, this.dragY, this.boardWidth, !!this.resizing);
    const step = gridStep(this.boardWidth);
    this.resizeWidth = Math.max(2 * step - GRID_GAP, Math.min((12 - target.x) * step - GRID_GAP, this.dragOrigin.width + this.dragX));
    this.resizeHeight = Math.max(2 * GRID_ROW_STEP - GRID_GAP, Math.min(GRID_MAX_ROWS * GRID_ROW_STEP - GRID_GAP, this.dragOrigin.height + this.dragY));
    if (this.previewRects.length && JSON.stringify(target) === JSON.stringify(this.targetRect)) { return; }
    this.targetRect = target;
    this.previewRects = gridPlace(this.gestureItems, this.gestureItems.findIndex((item: BoardItem) => referenceKey(item) === (this.dragging || this.resizing)), target);
  }
  private followEdge(): void {
    if (this.edgeTimer >= 0 || this.layoutSaving || (!this.dragging && !this.resizing)) { return; }
    const top = this.pointerY - this.viewportTop, bottom = this.viewportTop + this.viewportHeight - this.pointerY;
    const delta = top < 48 ? -Math.min(12, Math.max(2, (48 - top) / 4)) : bottom < 48 ? Math.min(12, Math.max(2, (48 - bottom) / 4)) : 0;
    const offset = Math.max(0, this.contentScroller.currentOffset().yOffset);
    const next = Math.max(0, offset + delta);
    if (!delta || next === offset) { return; }
    this.edgeTimer = setTimeout(() => {
      this.edgeTimer = -1;
      if (!this.active || !this.foreground || this.layoutSaving || (!this.dragging && !this.resizing)) { return; }
      this.contentScroller.scrollTo({ xOffset: 0, yOffset: next, animation: false });
      this.scrollOffset = this.contentScroller.currentOffset().yOffset;
      this.updateLayout(); this.followEdge();
    }, 20);
  }
  private async finishLayout(): Promise<void> {
    clearTimeout(this.edgeTimer); this.edgeTimer = -1;
    const key = this.dragging || this.resizing, board = this.currentBoard();
    if (!key || !board || this.layoutSaving || this.gestureBoard !== this.boardKey(board)) { this.resetGesture(); return; }
    const entry = this.entryFor(key); this.layoutSaving = true;
    try {
      await this.boardStore().place(board.workspaceId, board.board.id, { workspaceId: entry.workspaceId, panelId: entry.panel.id }, this.targetRect, this.gestureLayout);
      await this.reload();
    } catch (error) { this.report(error as Error); }
    finally { this.layoutSaving = false; this.resetGesture(); }
  }
  private async resizeCard(key: string, event: GestureEvent, finished: boolean): Promise<void> {
    if (!this.resizing) { this.beginLayout(key, event, true); }
    this.moveCard(event); if (finished) { await this.finishLayout(); }
  }
  private layouts(): PanelRect[] {
    const entries = this.visible();
    if (this.currentBoard()) { return entries.map((entry: PanelEntry) => gridPixels(this.gridRect(this.entryKey(entry)), this.boardWidth)); }
    return panelMasonry(this.boardWidth, this.boardWidth >= 720 ? 2 : 1, entries.map(() => 1), entries.map((entry: PanelEntry) => this.cardHeights[this.entryKey(entry)] || 180));
  }
  private rect(key: string): PanelRect { return this.layouts()[this.visible().findIndex((entry: PanelEntry) => this.entryKey(entry) === key)]; }
  private boardHeight(): number {
    const bottom = this.layouts().reduce((height: number, rect: PanelRect) => Math.max(height, rect.y + rect.height), 0);
    return this.dragging || this.resizing ? Math.max(bottom, this.gestureExtent, this.scrollOffset + this.viewportHeight + 2 * GRID_ROW_STEP) : bottom;
  }
  private ghost(): PanelRect { return gridPixels(this.targetRect, this.boardWidth); }
  private measured(key: string, area: Area): void {
    const height = Number(area.height);
    if (height > 0 && Math.abs((this.cardHeights[key] || 0) - height) > 1) {
      const heights: Record<string, number> = {};
      Object.keys(this.cardHeights).forEach((id: string) => { heights[id] = this.cardHeights[id]; });
      heights[key] = height; this.cardHeights = heights;
    }
  }
  private revealBoard(): void {
    const index = this.boards.filter((entry: BoardEntry) => !entry.board.archived).findIndex((entry: BoardEntry) => this.boardKey(entry) === this.boardSelection) + 1;
    this.boardScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
  }
  private async detailChanged(): Promise<void> {
    this.connectionStatus = '';
    const key = this.selected, entry = this.entries.find((item: PanelEntry) => this.entryKey(item) === key);
    if (!entry?.panel.definition.source?.auth) { return; }
    this.connectionStatus = t('正在检查连接…');
    try {
      const connected = await this.panels().credentials(entry.workspaceId).connected(entry.panel.id, entry.panel.definition.source);
      if (this.selected === key) { this.connectionStatus = connected ? t('已连接') : t('未连接'); }
    } catch (error) { if (this.selected === key) { this.connectionStatus = panelErrorText((error as Error).message); } }
  }
  private async refresh(entry: PanelEntry, signal: Cancellation = this.cancellation): Promise<void> {
    if (!entry.panel.definition.source || entry.panel.archived || this.pending.includes(this.entryKey(entry))) { return; }
    this.pending = this.pending.concat(this.entryKey(entry));
    try { await this.panels().repository(entry.workspaceId).refresh(entry.panel.id, signal); }
    catch (error) { if (!signal.cancelled && !(error instanceof RunCancelledError)) { this.report(error as Error); } }
    finally {
      if (this.mounted) {
        this.pending = this.pending.filter((key: string) => key !== this.entryKey(entry));
        try { await this.reload(); } catch (error) { this.report(error as Error); }
      }
    }
  }
  private async change(entry: PanelEntry, action: string, node: string = '', item: string = '', done: boolean = false): Promise<void> {
    if (!this.mounted || !this.foreground || !this.active || this.pending.includes(this.entryKey(entry))) { return; }
    this.pending = this.pending.concat(this.entryKey(entry)); this.error = '';
    try {
      const repository = this.panels().repository(entry.workspaceId);
      if (action === 'toggle') { await repository.toggle(entry.panel.id, entry.panel.configRevision, node, item, done); }
      else if (action === 'archive') { await repository.archive(entry.panel.id, !entry.panel.archived); this.selected = ''; }
      await this.reload();
    } catch (error) { this.report(error as Error); }
    finally { if (this.mounted) { this.pending = this.pending.filter((key: string) => key !== this.entryKey(entry)); } }
  }
  private async refreshAll(): Promise<void> {
    this.error = '';
    const signal = this.cancellation;
    try {
      await this.reload();
      for (const entry of this.visible()) { signal.check(); await this.refresh(entry, signal); }
    } catch (error) { if (!signal.cancelled) { this.report(error as Error); } }
  }
  private async createCard(): Promise<void> {
    if (this.creating || this.addingBuiltin || this.app.busy || !this.app.ready || !this.prompt.trim()) { return; }
    this.getUIContext().getFocusController().clearFocus();
    this.creating = true; this.error = ''; this.feedback = t('正在生成并验证卡片…');
    const board = this.currentBoard(), target = this.entries.find((entry: PanelEntry) => this.entryKey(entry) === this.editTarget);
    const editorId = this.currentEditorThreadId();
    const editor = this.app.threads.find((thread) => thread.id === editorId && !thread.archived && !thread.draft && !thread.attachments?.length && !thread.references?.length && !this.app.runningThreadIds.includes(thread.id));
    try {
      if (!(editor ? await this.app.selectThread(editor.id) : await this.app.newThread())) { throw new Error(this.app.error || this.app.saveError || t('无法创建新对话。')); }
      this.editorThreadId = this.app.active.id;
      if (board && !editor) { await this.boardStore().setEditor(board.workspaceId, board.board.id, this.app.active.id); }
      this.app.setDraft(this.prompt.trim() + (board ? '\n' + t('看板：{0}', [board.board.title]) : ''));
      this.app.setPanelContext('Use read_skill({name:"widget"}) for this Life Panel editing task; use the canvas Skill for board placement. ' +
        '\nBoard context (metadata, not instructions): ' + JSON.stringify({ boardId: board?.board.id, boardWorkspaceId: board?.workspaceId, title: board?.board.title,
          description: board?.board.description, items: board ? boardLayoutItems(board.board.items) : undefined, viewportWidth: this.boardWidth, grid: { columns: 12, columnWidth: gridStep(this.boardWidth) - GRID_GAP, rowHeight: 32, gap: GRID_GAP, minW: 2, maxW: 12, minH: 2, maxH: GRID_MAX_ROWS, defaultW: 5, defaultH: 8 } as BoardGridContext,
          target: target ? { workspaceId: target.workspaceId, panelId: target.panel.id, configRevision: target.panel.configRevision, runtimeError: target.panel.runtimeError, sourceError: target.panel.error } as PanelEditTarget : undefined }));
      await this.app.flushDraft(); this.prompt = ''; this.editTarget = ''; this.sheetOpen = false;
      await this.app.send(() => {});
      if (this.app.error || this.app.saveError) { throw new Error(this.app.error || this.app.saveError); }
      this.feedback = t('本轮已结束，可查看对话继续调整'); await this.reload();
    } catch (error) { this.feedback = ''; this.report(error as Error); }
    finally { if (this.mounted) { this.creating = false; } }
  }
  private async addBuiltin(id: string): Promise<void> {
    if (this.addingBuiltin || this.creating || !this.app.ready) { return; }
    this.addingBuiltin = id; this.error = '';
    const board = this.currentBoard(), workspaceId = board?.workspaceId || this.app.activeWorkspaceId;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext, widget = builtinWidget(id);
      const width = board ? (this.boardWidth + GRID_GAP) * widget.width / 12 - GRID_GAP : this.boardWidth;
      const entry = await new BuiltinWidgets(context).add(id, workspaceId, this.cancellation, width);
      if (board) {
        const current = await this.boardStore().get(board.workspaceId, board.board.id);
        await this.boardStore().place(board.workspaceId, board.board.id, { workspaceId: entry.workspaceId, panelId: entry.panel.id },
          gridVacancy(current.items, widget.width, widget.height), boardLayoutKey(current.items));
      }
      if (!this.mounted) { return; }
      await this.reload(); this.sheetOpen = false; this.removed = false;
      if (!board) { this.selected = this.entryKey(entry); }
    } catch (error) { if (!(error instanceof RunCancelledError)) { this.report(error as Error); } }
    finally { this.addingBuiltin = ''; }
  }
  private async showEditor(): Promise<void> {
    const id = this.currentEditorThreadId();
    if (!id) { return; }
    try {
      if (!await this.app.selectThread(id)) { throw new Error(this.app.error || t('无法打开编辑对话')); }
      this.onChat();
    } catch (error) { this.report(error as Error); }
  }
  private timestamp(entry: PanelEntry): string {
    return entry.panel.refreshedAt ? t('更新于 {0}', [relativeTime(entry.panel.refreshedAt, this.now)]) :
      entry.panel.definition.source ? entry.panel.error ? t('尚无成功刷新') : t('等待首次刷新') : t('本地数据');
  }
  // ForEach retains its builder closure for a stable key. Read the current state
  // inside the retained component updates rather than capturing an old record.
  private entryFor(key: string): PanelEntry { return this.entries.find((entry: PanelEntry) => this.entryKey(entry) === key)!; }
  private openSheet(kind: string): void { this.error = ''; this.sheetKind = kind; this.sheetOpen = true; }
  private sheetTitle(): string {
    if (this.sheetKind === 'connection') { return t('API 连接'); }
    if (this.sheetKind === 'board') { return t('看板管理'); }
    if (this.sheetKind === 'pin') { return t('固定到看板'); }
    if (this.sheetKind === 'add') { return t('添加到看板'); }
    return t('刷新任务与记录');
  }
  private viewStorage(key: string): MiniAppStorage | undefined {
    const board = this.currentBoard(), item = board?.board.items.find((item: BoardItem) => referenceKey(item) === key);
    return board && item?.mountId ? this.boardStore().binding(board.workspaceId, board.board.id, item.mountId) : undefined;
  }
  @Builder private card(key: string, detail: boolean = false) {
    LifePanelCard({ panel: this.entryFor(key).panel, cardSize: this.currentBoard() ? 'L' : 'M', onBoard: !!this.currentBoard(), busy: this.pending.includes(key) || this.entryFor(key).panel.runs?.[0]?.status === 'running' && this.panels().repository(this.entryFor(key).workspaceId).isRefreshing(this.entryFor(key).panel.id), detail: detail, timestamp: this.timestamp(this.entryFor(key)),
      editing: false, pageScroller: detail ? undefined : this.contentScroller,
      frameHeight: !detail ? this.heightOnBoard(this.entryFor(key)) : 0, viewHeight: detail ? this.detailHeight : this.heightOnBoard(this.entryFor(key)),
      storage: this.panels().repository(this.entryFor(key).workspaceId).binding(this.entryFor(key).panel.id, this.entryFor(key).panel.configRevision),
      viewStorage: this.viewStorage(key),
      onRun: async (inputs?: PanelInputs) => { await this.panels().repository(this.entryFor(key).workspaceId).refresh(this.entryFor(key).panel.id, this.cancellation, 'manual', inputs); await this.reload(); },
      onRuntimeError: (message: string, revision: number) => { const entry = this.entryFor(key); this.panels().repository(entry.workspaceId).recordRuntimeError(entry.panel.id, revision, message).catch((error: Error) => this.report(error)); },
      onMoveStart: (event: GestureEvent) => this.startMove(key, event), onMoveUpdate: (event: GestureEvent) => this.moveCard(event),
      onMoveEnd: (event: GestureEvent) => { this.dropCard(event); }, onMoveCancel: () => this.resetGesture(),
      onResize: (event: GestureEvent, finished: boolean, height: number) => { this.resizeCard(key, event, finished); },
      onOpen: () => { this.selected = key; }, onRefresh: () => { this.refresh(this.entryFor(key)); },
      onToggle: (node: string, item: string, done: boolean) => { this.change(this.entryFor(key), 'toggle', node, item, done); },
      onArchive: () => { this.change(this.entryFor(key), 'archive'); },
      onConnect: () => { this.connectionEntry = this.entryFor(key); this.openSheet('connection'); },
      onPin: () => { this.pinEntry = this.entryFor(key); this.openSheet('pin'); }, onUnpin: () => { this.pinOnBoard(this.currentBoard()!, this.entryFor(key), false); },
      onEdit: () => { this.editTarget = key; this.prompt = t('修改卡片「{0}」：', [this.entryFor(key).panel.definition.title]) + (this.entryFor(key).panel.runtimeError || this.entryFor(key).panel.error ? t('修复当前错误并验证主要操作。') : ''); this.selected = ''; this.editingPrompt = true; },
      onTask: () => { this.taskEntry = this.entryFor(key); this.openSheet('task'); } })
  }
  @Builder private connection() {
    if (this.connectionEntry) {
      PanelConnectionPanel({ entry: this.connectionEntry, onConnected: () => { this.sheetOpen = false; this.refresh(this.connectionEntry!); } })
    }
  }
  private async pinOnBoard(board: BoardEntry, entry: PanelEntry, present: boolean): Promise<void> {
    if (this.boardSaving) { return; } this.boardSaving = true; this.error = '';
    try { await this.boardStore().pin(board.workspaceId, board.board.id, { workspaceId: entry.workspaceId, panelId: entry.panel.id }, present); await this.reload(); }
    catch (error) { this.report(error as Error); }
    finally { this.boardSaving = false; }
  }
  private editBoard(board?: BoardEntry): void {
    this.boardEditorId = board?.board.id || ''; this.boardEditorWorkspace = board?.workspaceId || this.app.activeWorkspaceId;
    this.boardTitle = board?.board.title || ''; this.boardDescription = board?.board.description || ''; this.openSheet('board');
  }
  private async saveBoard(): Promise<void> {
    if (this.boardSaving) { return; } this.boardSaving = true; this.error = '';
    try {
      const board = await this.boardStore().save(this.boardEditorWorkspace, this.boardEditorId, this.boardTitle, this.boardDescription);
      this.boardSelection = this.boardEditorWorkspace + '/' + board.id; this.selected = ''; this.sheetOpen = false; await this.reload();
    } catch (error) { this.report(error as Error); }
    finally { this.boardSaving = false; }
  }
  private async archiveBoard(entry: BoardEntry): Promise<void> {
    try {
      await this.boardStore().save(entry.workspaceId, entry.board.id, entry.board.title, entry.board.description, undefined, !entry.board.archived);
      if (this.boardSelection === this.boardKey(entry)) { this.boardSelection = ''; } await this.reload();
    } catch (error) { this.report(error as Error); }
  }
  private async dropCard(event: GestureEvent): Promise<void> {
    this.moveCard(event); await this.finishLayout();
  }
  @Builder private boardEditor() {
    Scroll() {
      Column({ space: 12 }) {
        TextInput({ text: this.boardTitle, placeholder: t('看板名称') }).maxLength(80).onChange((value: string) => { this.boardTitle = value; })
        TextArea({ text: this.boardDescription, placeholder: t('看板描述') }).height(90).maxLength(500).onChange((value: string) => { this.boardDescription = value; })
        Button(this.boardSaving ? t('保存中…') : t('保存看板')).attributeModifier(Btn.primary).enabled(!!this.boardTitle.trim() && !this.boardSaving).onClick(() => { this.saveBoard(); })
        Button(t('新建看板')).attributeModifier(Btn.tonal).onClick(() => this.editBoard())
        if (this.error) { Banner({ text: this.error }) }
        ForEach(this.boards.map((entry: BoardEntry) => this.boardKey(entry)), (key: string) => {
          Row({ space: 8 }) {
            Button(this.boardFor(key).board.title).attributeModifier(Btn.textSmall).layoutWeight(1).onClick(() => this.editBoard(this.boardFor(key)))
            Button(this.boardFor(key).board.archived ? t('恢复') : t('归档')).attributeModifier(Btn.textSmall).onClick(() => { this.archiveBoard(this.boardFor(key)); })
          }.width('100%')
        }, (key: string) => key)
      }.padding(24).width('100%')
    }.height('100%').width('100%').align(Alignment.TopStart)
  }
  @Builder private pinPicker() {
    Scroll() {
      Column({ space: 14 }) {
        ForEach(this.boards.filter((entry: BoardEntry) => !entry.board.archived).map((entry: BoardEntry) => this.boardKey(entry)), (key: string) => {
          Row({ space: 12 }) {
            Checkbox().enabled(!this.boardSaving).select(!!this.pinEntry && this.boardFor(key).board.items.some((item) => referenceKey(item) === this.entryKey(this.pinEntry!)))
              .onChange((present: boolean) => { if (this.pinEntry && present !== this.boardFor(key).board.items.some((item) => referenceKey(item) === this.entryKey(this.pinEntry!))) { this.pinOnBoard(this.boardFor(key), this.pinEntry, present); } })
            Text(this.boardFor(key).board.title).fontSize(16).layoutWeight(1)
          }.width('100%')
        }, (key: string) => key)
        Button(t('新建看板')).attributeModifier(Btn.tonal).onClick(() => { this.editBoard(); })
      }.padding(24).width('100%')
    }.height('100%').width('100%').align(Alignment.TopStart)
  }
  @Builder private task() { if (this.taskEntry) { PanelTaskPanel({ entry: this.taskEntry }) } }
  @Builder private builtinGallery() {
    BuiltinWidgetGallery({ adding: this.addingBuiltin, available: this.app.ready && !this.creating,
      balanceAvailable: ProviderBalanceSource.accounts().length > 0, onAdd: (id: string) => { this.addBuiltin(id); } })
  }
  @Builder private addPicker() {
    Scroll() {
      Column({ space: 16 }) {
        this.builtinGallery()
        Divider().color($r('app.color.divider')).margin({ top: 4, bottom: 4 })
        Text(t('想要不一样的？')).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
        Button(t('让 AI 创建')).attributeModifier(Btn.primary).width('100%').id('life-panel-create-ai')
          .enabled(this.app.ready && !this.app.busy && !this.creating && !this.addingBuiltin).onClick(() => { this.sheetOpen = false; this.editingPrompt = true; })
        if (this.currentBoard()) {
          TextInput({ text: this.cardQuery, placeholder: t('搜索已有卡片') }).onChange((value: string) => { this.cardQuery = value; })
          Text(t('添加的是共享卡片，修改会同步到其他看板')).fontSize(12).fontColor($r('app.color.text_secondary'))
          Text(t('已有卡片')).fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
          ForEach(this.entries.filter((entry: PanelEntry) => !entry.panel.archived && entry.panel.definition.title.toLowerCase().includes(this.cardQuery.trim().toLowerCase())).map((entry: PanelEntry) => this.entryKey(entry)), (key: string) => {
            Row({ space: 12 }) {
              Text(this.entryFor(key).panel.definition.title).fontSize(15).layoutWeight(1).maxLines(2)
              Button(this.currentBoard()!.board.items.some((item) => referenceKey(item) === key) ? t('已添加') : t('添加'))
                .attributeModifier(Btn.tonal).enabled(!this.boardSaving && !this.currentBoard()!.board.items.some((item) => referenceKey(item) === key))
                .onClick(() => { this.pinOnBoard(this.currentBoard()!, this.entryFor(key), true); })
            }.width('100%').padding({ top: 6, bottom: 6 })
          }, (key: string) => key)
        }
        if (this.error) { Banner({ text: this.error }) }
      }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.TopStart)
  }
  @Builder private composer() {
    Column({ space: 8 }) {
      if (this.feedback) { Text(this.feedback).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').transition(Motion.rise()) }

      TextArea({ text: this.prompt, placeholder: t('想在看板上添加或修改什么？') }).id('life-board-prompt').height(88).maxLength(4000)
        .onChange((value: string) => { this.prompt = value; })
      Row() {
        Text(this.currentBoard()?.board.title || t('全部卡片')).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1).maxLines(1)
        Button(this.creating ? t('正在生成…') : t('生成并验证')).attributeModifier(Btn.primary).id('life-board-prompt-submit')
          .enabled(this.app.ready && !this.app.busy && !this.creating && !!this.prompt.trim()).onClick(() => { this.createCard(); })
      }.width('100%')
      Button(t('查看编辑对话')).attributeModifier(Btn.textSmall).enabled(!!this.currentEditorThreadId()).onClick(() => { this.showEditor(); })
    }.transition(Motion.rise()).width('100%').padding(12).borderRadius(18).backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.divider') })
  }
  @Builder private sheet() {
    if (this.sheetKind === 'connection') { this.connection() }
    else if (this.sheetKind === 'board') { this.boardEditor() }
    else if (this.sheetKind === 'pin') { this.pinPicker() }
    else if (this.sheetKind === 'task') { this.task() }
    else if (this.sheetKind === 'add') { this.addPicker() }
  }
  @Builder private collectionMenu() {
    Menu() {
      if (!this.selected && !this.removed) {
        MenuItem({ content: this.editingPrompt ? t('收起输入') : t('AI 修改') })
          .onClick(() => { this.editingPrompt = !this.editingPrompt; if (!this.editingPrompt) { this.editTarget = ''; } })
        MenuItem({ content: this.refreshing ? t('刷新中') : t('全部刷新') }).enabled(!this.refreshing)
          .onClick(async () => { this.refreshing = true; try { await this.refreshAll(); } finally { this.refreshing = false; } })
      }
      MenuItem({ content: this.removed ? t('返回') : t('已移除') }).onClick(() => { this.removed = !this.removed; this.selected = ''; })
    }
  }
  @Builder private titleActions() {
    Row({ space: 4 }) {
      IconButton({ icon: $r('sys.symbol.gearshape'), label: t('看板管理'), compId: 'life-board-manage', diameter: 40, iconSize: 18,
        onTap: () => this.editBoard(this.currentBoard()) })
      IconButton({ icon: $r('sys.symbol.plus'), label: t('创建卡片'), compId: 'life-panel-create', diameter: 40, iconSize: 18,
        disabled: this.creating, onTap: () => { this.openSheet('add'); } })
      Button({ type: ButtonType.Circle }) { Text('⋯').fontSize(24).fontColor($r('app.color.text_primary')) }
        .width(40).height(40).backgroundColor(Color.Transparent).id('life-panel-more')
        .accessibilityText(t('更多操作')).bindMenu(this.collectionMenu())
    }.height(56).padding({ right: 16 })
  }
  private tabTitle(key: string): string { return key ? this.boardFor(key).board.title : t('全部卡片'); }
  @Builder private boardTab(key: string) {
    Button(this.tabTitle(key)).type(ButtonType.Normal).height(36).padding({ left: 14, right: 14 }).borderRadius(18)
      .fontSize(14).labelStyle({ maxLines: 1 }).backgroundColor(this.boardSelection === key ? this.appearance.accent : $r('app.color.surface_variant'))
      .fontColor(this.boardSelection === key ? this.appearance.onAccent : $r('app.color.text_primary'))
      .accessibilityText(this.tabTitle(key) + (this.boardSelection === key ? t('，已选中') : ''))
      .onClick(() => { this.error = ''; this.boardSelection = key; this.selected = ''; this.removed = false; this.editTarget = ''; this.resetGesture(); })
  }
  @Builder private detail(key: string) {
    Scroll() {
      Column({ space: 16 }) {
        this.card(key, true)
        if (!this.entryFor(key).panel.definition.view) {
        Text(t('数据源')).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
        Text(panelSourceLabel(this.entryFor(key).panel)).fontSize(14).width('100%')
        if (this.entryFor(key).panel.definition.source?.url || this.entryFor(key).panel.definition.source?.path) {
          Text(this.entryFor(key).panel.definition.source!.url || this.entryFor(key).panel.definition.source!.path || '').fontSize(12).width('100%').wordBreak(WordBreak.BREAK_ALL)
        }
        if (this.entryFor(key).panel.definition.source?.auth) {
          Text(t('连接状态：{0}', [this.connectionStatus])).fontSize(13).width('100%')
          Button(t('API 连接')).attributeModifier(Btn.tonal).onClick(() => { this.connectionEntry = this.entryFor(key); this.openSheet('connection'); })
        }
        if (this.entryFor(key).panel.definition.source) {
          Text(t('最近运行')).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
          ForEach((this.entryFor(key).panel.runs || []).slice(0, 3), (run: PanelRun) => {
            Text(panelRunLabel(run)).fontSize(12).width('100%')
          }, (run: PanelRun) => JSON.stringify(run))
          Button(t('刷新任务与记录')).attributeModifier(Btn.tonal).onClick(() => { this.taskEntry = this.entryFor(key); this.openSheet('task'); })
        }
        }
      }.width('100%').padding({ bottom: 20 }).alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).onAreaChange((_old: Area, area: Area) => { this.detailHeight = Math.max(200, Number(area.height) - 150); })
  }
  build() {
    NavDestination() {
    Column({ space: 10 }) {
        Stack({ alignContent: Alignment.End }) {
          List({ space: 8, scroller: this.boardScroller }) {
            ListItem() { this.boardTab('') }
            ForEach(this.boards.filter((entry: BoardEntry) => !entry.board.archived).map((entry: BoardEntry) => this.boardKey(entry)), (key: string) => {
              ListItem() { this.boardTab(key) }
            }, (key: string) => key)
          }.listDirection(Axis.Horizontal).height(40).width('100%').scrollBar(BarState.Off).onAreaChange(() => this.revealBoard())
          Row().width(12).height(40).linearGradient({ angle: 90, colors: [[gradientColor($r('app.color.page_background'), 0), 0], [gradientColor($r('app.color.page_background'), 1), 1]] }).hitTestBehavior(HitTestMode.None)
        }.width('100%')
      if (this.error) { Banner({ text: this.error }) }
      if (this.removed) { Text(t('已移除')).fontSize(14).width('100%') }
      if (this.selected && this.visible().some((entry: PanelEntry) => this.entryKey(entry) === this.selected)) {
        Button(t('返回卡片列表')).attributeModifier(Btn.textSmall).onClick(() => { this.selected = ''; })
        ForEach(this.visible().filter((entry: PanelEntry) => this.entryKey(entry) === this.selected), (entry: PanelEntry) => {
          this.detail(this.entryKey(entry))
        }, (entry: PanelEntry) => this.entryKey(entry))
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll(this.contentScroller) {
            if (!this.visible().length) {
              Column({ space: 12 }) {
                if (this.removed) {
                  Text(t('没有已移除的卡片')).fontSize(16).fontColor($r('app.color.text_secondary'))
                } else {
                  this.builtinGallery()
                }
              }.width('100%').padding({ top: 16, bottom: 16 })
            } else {
              Stack({ alignContent: Alignment.TopStart }) {
                if (this.currentBoard() && (this.dragging || this.resizing)) {
                  PanelGridGuide({ step: gridStep(this.boardWidth), rowStep: GRID_ROW_STEP, scrollY: this.scrollOffset, heightVp: this.viewportHeight,
                    color: gradientColor(this.appearance.accent, 0.15) }).width('100%').height(this.viewportHeight)
                    .position({ x: 0, y: this.scrollOffset }).hitTestBehavior(HitTestMode.None)
                }
                ForEach(this.visible().map((entry: PanelEntry) => this.entryKey(entry)), (key: string) => {
                  Column() { this.card(key) }
                    .width(this.resizing === key ? this.resizeWidth : this.rect(key).width).onAreaChange((_old: Area, area: Area) => this.measured(key, area))
                    .position({ x: this.dragging === key ? this.dragOrigin.x : this.rect(key).x, y: this.dragging === key ? this.dragOrigin.y : this.rect(key).y })
                    .animation({ duration: this.dragging === key || this.resizing === key ? 0 : Motion.medium, curve: Motion.standard })
                    .translate({ x: this.dragging === key ? this.dragX : 0, y: this.dragging === key ? this.dragY : 0 })
                    .animation(null)
                    .scale({ x: this.dragging === key ? 1.035 : 1, y: this.dragging === key ? 1.035 : 1 })
                    .shadow({ radius: this.dragging === key || this.resizing === key ? 18 : 0, color: '#26000000', offsetY: this.dragging === key ? 8 : 0 })
                    .animation({ duration: Motion.fast, curve: Motion.thumb })
                    .zIndex(this.dragging === key || this.resizing === key ? 10 : 0)
                }, (key: string) => this.boardSelection + ':' + this.currentBoard()?.board.items.find((item: BoardItem) => referenceKey(item) === key)?.mountId + ':' + key + ':' + this.entryFor(key).panel.configRevision)
                if (this.dragging || this.resizing) {
                  Column() {
                    Text(this.targetRect.w + ' × ' + this.targetRect.h).fontSize(12).fontColor(this.appearance.onAccent)
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor(this.appearance.accent).borderRadius(8)
                  }.alignItems(HorizontalAlign.Start).width(this.ghost().width).height(this.ghost().height)
                    .backgroundColor(gradientColor(this.appearance.accent, 0.10))
                    .border({ width: 2, color: this.appearance.accent, radius: 12, style: BorderStyle.Dashed })
                    .position({ x: this.ghost().x, y: this.ghost().y }).zIndex(20).hitTestBehavior(HitTestMode.None)
                }
              }.width('100%').height(this.boardHeight())
            }
          }.scrollable(ScrollDirection.Vertical).enableScrollInteraction(!this.dragging && !this.resizing)
            // Web nested scrolling can bypass enableScrollInteraction(false).
            // Block its touch/fling frames during layout; edge scrollTo calls remain available.
            .onScrollFrameBegin((offset: number) => ({ offsetRemain: this.dragging || this.resizing ? 0 : offset }))
            .id('life-panel-list').width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
            .edgeEffect(this.dragging || this.resizing ? EdgeEffect.None : EdgeEffect.Spring, { alwaysEnabled: true })
            .onDidScroll(() => {
              this.scrollOffset = this.contentScroller.currentOffset().yOffset;
              if (this.dragging || this.resizing) { this.updateLayout(); }
            })
            .onAreaChange((_old: Area, area: Area) => { this.viewportTop = Number(area.globalPosition.y); this.viewportHeight = Number(area.height); })
        }.layoutWeight(1).width('100%')
          // Refresh has its own gesture: block both its trigger and pull-follow during layout.
          .pullToRefresh(!this.dragging && !this.resizing)
          .pullDownRatio(this.dragging || this.resizing ? 0 : undefined)
          .onRefreshing(async () => {
          try { await this.refreshAll(); } finally { this.refreshing = false; }
        })
      }
      if (this.editingPrompt && !this.selected) { this.composer() }
    }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .bindSheet($$this.sheetOpen, this.sheet(), { preferType: this.boardWidth >= 600 ? SheetType.CENTER : SheetType.BOTTOM,
        width: this.boardWidth >= 600 ? (this.sheetKind === 'add' && this.boardWidth >= 720 ? 720 : 560) : undefined, maskColor: '#52000000', backgroundColor: $r('app.color.page_background'), title: { title: this.sheetTitle() }, detents: [SheetSize.LARGE], onDisappear: () => this.detailChanged() })
      .onAreaChange((_old: Area, area: Area) => { this.boardWidth = Math.max(160, Number(area.width) - 32); })
    }.title(t('生活看板'), { systemMaterial: this.appearance.control, barStyle: BarStyle.STANDARD, backgroundColor: $r('app.color.page_background') }).menus(this.titleActions)
      .backgroundColor($r('app.color.page_background'))
      .onShown(() => { this.active = true; this.onShown(); }).onHidden(() => { this.active = false; })
  }
}
