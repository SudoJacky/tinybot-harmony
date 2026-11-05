import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, relativeTime } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';
import { PanelEntry, PanelCell, panelCells, panelDue } from '../model/LifePanel';
import { LifePanels } from '../services/LifePanels';
import { Cancellation, RunCancelledError } from '../services/Cancellation';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { LifePanelCard } from './LifePanelCard';
import { PanelConnectionPanel } from './PanelConnectionPanel';
import { PanelTaskPanel } from './PanelTaskPanel';
import { LifeBoards } from '../services/LifeBoards';
import { PanelChanges } from '../services/PanelChanges';
import { BoardEntry, PanelTarget, parsePanelTarget, referenceKey } from '../model/LifeBoard';
import { PanelRecord } from '../model/LifePanel';

@Component
export struct LifePanelsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('activityChanged') private foreground: boolean = true;
  @Prop @Watch('activityChanged') active: boolean = true;
  @Prop @Watch('targetChanged') requestedTarget: string = '';
  @ObjectLink app: ChatViewModel;
  onChat: () => void = () => {};
  @State private entries: PanelEntry[] = [];
  @State private boards: BoardEntry[] = [];
  @State private boardSelection: string = '';
  @State private boardEditorOpen: boolean = false;
  @State private boardEditorId: string = '';
  @State private boardEditorWorkspace: string = '';
  @State private boardTitle: string = '';
  @State private boardDescription: string = '';
  @State private pinOpen: boolean = false;
  @State private pinEntry: PanelEntry | undefined = undefined;
  @State private taskOpen: boolean = false;
  @State private taskEntry: PanelEntry | undefined = undefined;
  @State private dragging: string = '';
  @State private dragX: number = 0;
  @State private dragY: number = 0;
  @State private boardWidth: number = 360;
  @State private now: number = Date.now();
  @State private error: string = '';
  @State private pending: string[] = [];
  @State private selected: string = '';
  @State private removed: boolean = false;
  @State private creating: boolean = false;
  @State private connectionOpen: boolean = false;
  @State private connectionEntry: PanelEntry | undefined = undefined;
  private store?: LifePanels;
  private mounted: boolean = false;
  private timer: number = -1;
  private cancellation: Cancellation = new Cancellation();
  private scanning: boolean = false;
  private unsubscribe?: () => void;
  private lastTarget: string = '';
  private boardStore(): LifeBoards { return new LifeBoards((this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir); }
  private boardKey(entry: BoardEntry): string { return entry.workspaceId + '/' + entry.board.id; }
  private currentBoard(): BoardEntry | undefined { return this.boards.find((entry: BoardEntry) => this.boardKey(entry) === this.boardSelection); }
  private panels(): LifePanels {
    if (!this.store) { this.store = new LifePanels((this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir); }
    return this.store;
  }
  aboutToAppear(): void { this.mounted = true; this.activityChanged(); this.unsubscribe = PanelChanges.subscribe(() => { if (this.mounted && this.active) { this.reload().catch((error: Error) => this.report(error)); } }); }
  aboutToDisappear(): void { this.mounted = false; this.stop(); this.unsubscribe?.(); }
  private stop(): void { clearTimeout(this.timer); this.timer = -1; this.cancellation.cancel(); }
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
    this.reload().catch((error: Error) => { if (!signal.cancelled) { this.report(error); } }).finally(() => {
      this.scanning = false;
      if (this.mounted && this.foreground && this.active && !signal.cancelled) { this.timer = setTimeout(() => this.scan(), 30000); }
    });
  }
  private entryKey(entry: PanelEntry): string { return entry.workspaceId + '/' + entry.panel.id; }
  private visible(): PanelEntry[] {
    const entries = this.entries.filter((entry: PanelEntry) => entry.panel.archived === this.removed), board = this.currentBoard();
    if (!board) { return entries; }
    return board.board.items.flatMap((item) => entries.filter((entry: PanelEntry) => this.entryKey(entry) === referenceKey(item)));
  }
  private sizeOnBoard(entry: PanelEntry): string {
    const item = this.currentBoard()?.board.items.find((item) => referenceKey(item) === this.entryKey(entry));
    return item?.size || entry.panel.definition.size;
  }
  private cells(): PanelCell[] { return panelCells(this.visible().map((entry: PanelEntry) => this.sizeOnBoard(entry)), this.columns()); }
  private columns(): number { return this.boardWidth >= 900 ? 4 : this.boardWidth >= 600 ? 3 : 2; }
  private unit(): number { return (this.boardWidth - 12 * (this.columns() - 1)) / this.columns(); }
  private cell(index: number): PanelCell { return this.cells()[index]; }
  private boardHeight(): number { return this.cells().reduce((height: number, cell: PanelCell) => Math.max(height, (cell.row + cell.rows) * 202 - 12), 0); }
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
      else if (this.currentBoard()) {
        const board = this.currentBoard()!, index = board.board.items.findIndex((item) => referenceKey(item) === this.entryKey(entry));
        await this.boardStore().arrange(board.workspaceId, board.board.id, { workspaceId: entry.workspaceId, panelId: entry.panel.id },
          index + 1 < board.board.items.length ? referenceKey(board.board.items[index + 1]) : '', action);
      } else { await repository.resize(entry.panel.id, action); }
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
    if (this.creating || this.app.busy || !this.app.ready) { return; }
    this.creating = true;
    try {
      if (!await this.app.newThread()) { throw new Error(this.app.error || this.app.saveError || t('无法创建新对话。')); }
      this.app.setDraft(t('帮我创建一个 Life Panel 卡片。请先确认用途，再读取 get_life_panel_catalog，通过 publish_life_panel 固定卡片。') +
        (this.currentBoard() ? '\nBoard: ' + JSON.stringify({ boardId: this.currentBoard()!.board.id, boardWorkspaceId: this.currentBoard()!.workspaceId }) : ''));
      await this.app.flushDraft(); this.onChat();
    } catch (error) { this.report(error as Error); }
    finally { if (this.mounted) { this.creating = false; } }
  }
  private timestamp(entry: PanelEntry): string {
    return entry.panel.refreshedAt ? t('更新于 {0}', [relativeTime(entry.panel.refreshedAt, this.now)]) :
      entry.panel.definition.source ? t('等待首次刷新') : t('本地数据');
  }
  @Builder private card(entry: PanelEntry, detail: boolean = false) {
    LifePanelCard({ panel: entry.panel, cardSize: this.sizeOnBoard(entry), onBoard: !!this.currentBoard(), busy: this.pending.includes(this.entryKey(entry)) || entry.panel.runs?.[0]?.status === 'running' && this.panels().repository(entry.workspaceId).isRefreshing(entry.panel.id), detail: detail, timestamp: this.timestamp(entry),
      onOpen: () => { this.selected = this.entryKey(entry); }, onRefresh: () => { this.refresh(entry); },
      onToggle: (node: string, item: string, done: boolean) => { this.change(entry, 'toggle', node, item, done); },
      onSize: (size: string) => { this.change(entry, size); }, onArchive: () => { this.change(entry, 'archive'); },
      onConnect: () => { this.connectionEntry = entry; this.connectionOpen = true; },
      onPin: () => { this.pinEntry = entry; this.pinOpen = true; }, onUnpin: () => { this.pinOnBoard(this.currentBoard()!, entry, false); },
      onTask: () => { this.taskEntry = entry; this.taskOpen = true; } })
  }
  @Builder private connection() {
    if (this.connectionEntry) {
      PanelConnectionPanel({ entry: this.connectionEntry, onConnected: () => { this.connectionOpen = false; this.refresh(this.connectionEntry!); } })
    }
  }
  private async pinOnBoard(board: BoardEntry, entry: PanelEntry, present: boolean): Promise<void> {
    try { await this.boardStore().pin(board.workspaceId, board.board.id, { workspaceId: entry.workspaceId, panelId: entry.panel.id }, present); await this.reload(); }
    catch (error) { this.report(error as Error); }
  }
  private editBoard(board?: BoardEntry): void {
    this.boardEditorId = board?.board.id || ''; this.boardEditorWorkspace = board?.workspaceId || this.app.activeWorkspaceId;
    this.boardTitle = board?.board.title || ''; this.boardDescription = board?.board.description || ''; this.boardEditorOpen = true;
  }
  private async saveBoard(): Promise<void> {
    try {
      const board = await this.boardStore().save(this.boardEditorWorkspace, this.boardEditorId, this.boardTitle, this.boardDescription);
      this.boardSelection = this.boardEditorWorkspace + '/' + board.id; this.selected = ''; this.boardEditorOpen = false; await this.reload();
    } catch (error) { this.report(error as Error); }
  }
  private async archiveBoard(entry: BoardEntry): Promise<void> {
    try {
      await this.boardStore().save(entry.workspaceId, entry.board.id, entry.board.title, entry.board.description, undefined, !entry.board.archived);
      if (this.boardSelection === this.boardKey(entry)) { this.boardSelection = ''; } await this.reload();
    } catch (error) { this.report(error as Error); }
  }
  private async dropCard(entry: PanelEntry, index: number, event: GestureEvent): Promise<void> {
    this.dragging = ''; this.dragX = 0; this.dragY = 0;
    const board = this.currentBoard(); if (!board) { return; }
    const cell = this.cell(index), x = (cell.column + cell.columns / 2) * (this.unit() + 12) + event.offsetX,
      y = (cell.row + cell.rows / 2) * 202 + event.offsetY;
    const target = this.cells().findIndex((candidate: PanelCell) => x >= candidate.column * (this.unit() + 12) &&
      x < (candidate.column + candidate.columns) * (this.unit() + 12) && y >= candidate.row * 202 && y < (candidate.row + candidate.rows) * 202);
    if (target === index || x < 0 || x > this.boardWidth || y < 0) { return; }
    try {
      await this.boardStore().arrange(board.workspaceId, board.board.id, { workspaceId: entry.workspaceId, panelId: entry.panel.id },
        target < 0 ? '' : this.entryKey(this.visible()[target])); await this.reload();
    } catch (error) { this.report(error as Error); }
  }
  @Builder private boardEditor() {
    Scroll() {
      Column({ space: 12 }) {
        TextInput({ text: this.boardTitle, placeholder: t('看板名称') }).maxLength(80).onChange((value: string) => { this.boardTitle = value; })
        TextArea({ text: this.boardDescription, placeholder: t('看板描述') }).height(90).maxLength(500).onChange((value: string) => { this.boardDescription = value; })
        Button(t('保存看板')).attributeModifier(Btn.primary).enabled(!!this.boardTitle.trim()).onClick(() => { this.saveBoard(); })
        Button(t('新建看板')).attributeModifier(Btn.tonal).onClick(() => this.editBoard())
        if (this.error) { Banner({ text: this.error }) }
        ForEach(this.boards, (entry: BoardEntry) => {
          Row({ space: 8 }) {
            Button(entry.board.title).attributeModifier(Btn.textSmall).layoutWeight(1).onClick(() => this.editBoard(entry))
            Button(entry.board.archived ? t('恢复') : t('归档')).attributeModifier(Btn.textSmall).onClick(() => { this.archiveBoard(entry); })
          }.width('100%')
        }, (entry: BoardEntry) => this.boardKey(entry))
      }.padding(24).width('100%')
    }.height('100%').width('100%')
  }
  @Builder private pinPicker() {
    Scroll() {
      Column({ space: 14 }) {
        ForEach(this.boards.filter((entry: BoardEntry) => !entry.board.archived), (entry: BoardEntry) => {
          Row({ space: 12 }) {
            Checkbox().select(!!this.pinEntry && entry.board.items.some((item) => referenceKey(item) === this.entryKey(this.pinEntry!)))
              .onChange((present: boolean) => { if (this.pinEntry && present !== entry.board.items.some((item) => referenceKey(item) === this.entryKey(this.pinEntry!))) { this.pinOnBoard(entry, this.pinEntry, present); } })
            Text(entry.board.title).fontSize(16).layoutWeight(1)
          }.width('100%')
        }, (entry: BoardEntry) => this.boardKey(entry))
        Button(t('新建看板')).attributeModifier(Btn.tonal).onClick(() => { this.pinOpen = false; this.editBoard(); })
      }.padding(24).width('100%')
    }.height('100%').width('100%')
  }
  @Builder private task() { if (this.taskEntry) { PanelTaskPanel({ entry: this.taskEntry }) } }
  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Scroll() {
          Row({ space: 8 }) {
            Button(t('全部卡片')).attributeModifier(Btn.tonal).onClick(() => { this.boardSelection = ''; this.selected = ''; })
            ForEach(this.boards.filter((entry: BoardEntry) => !entry.board.archived), (entry: BoardEntry) => {
              Button(entry.board.title).attributeModifier(Btn.tonal).fontWeight(this.boardSelection === this.boardKey(entry) ? FontWeight.Bold : FontWeight.Normal)
                .onClick(() => { this.boardSelection = this.boardKey(entry); this.selected = ''; this.removed = false; })
            }, (entry: BoardEntry) => this.boardKey(entry))
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
        Button(t('看板管理')).attributeModifier(Btn.tonal).onClick(() => this.editBoard(this.currentBoard()))
      }.width('100%')
      Row({ space: 8 }) {
        Button(t('创建卡片')).attributeModifier(Btn.primary).id('life-panel-create').enabled(this.app.ready && !this.app.busy && !this.creating).onClick(() => { this.createCard(); })
        Blank()
        Button(this.removed ? t('返回') : t('已移除')).attributeModifier(Btn.tonal).onClick(() => { this.removed = !this.removed; this.selected = ''; })
        Button(t('刷新')).attributeModifier(Btn.tonal).id('life-panel-refresh').enabled(!this.pending.length).onClick(() => { this.refreshAll(); })
      }.width('100%')
      if (this.error) { Banner({ text: this.error }) }
      if (this.currentBoard() && !this.selected) {
        Text(this.currentBoard()!.board.description || t('长按卡片拖拽排序；尺寸和位置会保存在当前看板。')).fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      if (this.selected && this.visible().some((entry: PanelEntry) => this.entryKey(entry) === this.selected)) {
        Button(t('返回卡片列表')).attributeModifier(Btn.tonal).onClick(() => { this.selected = ''; })
        ForEach(this.visible().filter((entry: PanelEntry) => this.entryKey(entry) === this.selected), (entry: PanelEntry) => {
          Column() { this.card(entry, true) }.layoutWeight(1).width('100%')
        }, (entry: PanelEntry) => this.entryKey(entry) + ':' + entry.panel.configRevision)
      } else if (!this.visible().length) {
        Column({ space: 12 }) {
          Text(t('把关心的事情放在这里')).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(t('让 Tinybot 创建指标、清单或趋势卡片。支持手动刷新，应用在前台时会更新到期数据。'))
            .fontSize(14).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Stack({ alignContent: Alignment.TopStart }) {
            ForEach(this.visible(), (entry: PanelEntry, index: number) => {
              Column() { this.card(entry) }
                .width(this.cell(index).columns * (this.unit() + 12) - 12)
                .height(this.cell(index).rows * 202 - 12)
                .position({ x: this.cell(index).column * (this.unit() + 12), y: this.cell(index).row * 202 })
                .translate({ x: this.dragging === this.entryKey(entry) ? this.dragX : 0, y: this.dragging === this.entryKey(entry) ? this.dragY : 0 })
                .zIndex(this.dragging === this.entryKey(entry) ? 10 : 0)
                .gesture(GestureGroup(GestureMode.Sequence, LongPressGesture({ repeat: false, duration: 450 }),
                  PanGesture().onActionStart(() => { if (this.currentBoard()) { this.dragging = this.entryKey(entry); } })
                    .onActionUpdate((event: GestureEvent) => { if (this.dragging) { this.dragX = event.offsetX; this.dragY = event.offsetY; } })
                    .onActionEnd((event: GestureEvent) => { if (this.dragging) { this.dropCard(entry, index, event); } })
                ).onCancel(() => { this.dragging = ''; this.dragX = 0; this.dragY = 0; }))
            }, (entry: PanelEntry) => this.entryKey(entry) + ':' + entry.panel.configRevision)
          }.width('100%').height(this.boardHeight())
        }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
      }
    }.width('100%').height('100%').padding(16)
      .bindSheet($$this.connectionOpen, this.connection(), { title: { title: t('API 连接') }, detents: [SheetSize.LARGE] })
      .bindSheet($$this.boardEditorOpen, this.boardEditor(), { title: { title: t('看板管理') }, detents: [SheetSize.LARGE] })
      .bindSheet($$this.pinOpen, this.pinPicker(), { title: { title: t('固定到看板') }, detents: [SheetSize.LARGE] })
      .bindSheet($$this.taskOpen, this.task(), { title: { title: t('刷新任务与记录') }, detents: [SheetSize.LARGE] })
      .onAreaChange((_old: Area, area: Area) => { this.boardWidth = Math.max(160, Number(area.width) - 32); })
  }
}
