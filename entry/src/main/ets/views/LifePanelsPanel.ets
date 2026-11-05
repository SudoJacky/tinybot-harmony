import { PanelRect, panelMasonry, panelSourceLabel, panelRunLabel, panelErrorText } from '../model/PanelPresentation';
import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, relativeTime, gradientColor } from '../common/Theme';
import { Banner, IconButton } from '../common/Widgets';
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
import { PanelRecord, PanelRun } from '../model/LifePanel';

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
  @State private connectionEntry: PanelEntry | undefined = undefined;
  @State private refreshing: boolean = false;
  @State private cardHeights: Record<string, number> = {};
  @State private connectionStatus: string = '';
  private boardScroller: Scroller = new Scroller();
  private store?: LifePanels;
  private mounted: boolean = false;
  private timer: number = -1;
  private cancellation: Cancellation = new Cancellation();
  private scanning: boolean = false;
  private unsubscribe?: () => void;
  private lastTarget: string = '';
  private boardStore(): LifeBoards { return new LifeBoards((this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir); }
  private boardKey(entry: BoardEntry): string { return entry.workspaceId + '/' + entry.board.id; }
  private boardFor(key: string): BoardEntry { return this.boards.find((entry: BoardEntry) => this.boardKey(entry) === key)!; }
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
  private columns(): number { return this.boardWidth >= 900 ? 4 : this.boardWidth >= 600 ? 3 : 2; }
  private layouts(): PanelRect[] {
    const entries = this.visible(), columns = this.columns();
    return panelMasonry(this.boardWidth, columns, entries.map((entry: PanelEntry) => entries.length === 1 ? columns : this.sizeOnBoard(entry) === 'S' ? 1 : this.sizeOnBoard(entry) === 'L' ? columns : 2),
      entries.map((entry: PanelEntry) => this.cardHeights[this.entryKey(entry)] || 180));
  }
  private rect(key: string): PanelRect { return this.layouts()[this.visible().findIndex((entry: PanelEntry) => this.entryKey(entry) === key)]; }
  private boardHeight(): number { return this.layouts().reduce((height: number, rect: PanelRect) => Math.max(height, rect.y + rect.height), 0); }
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
    return t('刷新任务与记录');
  }
  @Builder private card(key: string, detail: boolean = false) {
    LifePanelCard({ panel: this.entryFor(key).panel, cardSize: this.sizeOnBoard(this.entryFor(key)), onBoard: !!this.currentBoard(), busy: this.pending.includes(key) || this.entryFor(key).panel.runs?.[0]?.status === 'running' && this.panels().repository(this.entryFor(key).workspaceId).isRefreshing(this.entryFor(key).panel.id), detail: detail, timestamp: this.timestamp(this.entryFor(key)),
      onOpen: () => { this.selected = key; }, onRefresh: () => { this.refresh(this.entryFor(key)); },
      onToggle: (node: string, item: string, done: boolean) => { this.change(this.entryFor(key), 'toggle', node, item, done); },
      onSize: (size: string) => { this.change(this.entryFor(key), size); }, onArchive: () => { this.change(this.entryFor(key), 'archive'); },
      onConnect: () => { this.connectionEntry = this.entryFor(key); this.openSheet('connection'); },
      onPin: () => { this.pinEntry = this.entryFor(key); this.openSheet('pin'); }, onUnpin: () => { this.pinOnBoard(this.currentBoard()!, this.entryFor(key), false); },
      onTask: () => { this.taskEntry = this.entryFor(key); this.openSheet('task'); } })
  }
  @Builder private connection() {
    if (this.connectionEntry) {
      PanelConnectionPanel({ entry: this.connectionEntry, onConnected: () => { this.sheetOpen = false; this.refresh(this.connectionEntry!); } })
    }
  }
  private async pinOnBoard(board: BoardEntry, entry: PanelEntry, present: boolean): Promise<void> {
    try { await this.boardStore().pin(board.workspaceId, board.board.id, { workspaceId: entry.workspaceId, panelId: entry.panel.id }, present); await this.reload(); }
    catch (error) { this.report(error as Error); }
  }
  private editBoard(board?: BoardEntry): void {
    this.boardEditorId = board?.board.id || ''; this.boardEditorWorkspace = board?.workspaceId || this.app.activeWorkspaceId;
    this.boardTitle = board?.board.title || ''; this.boardDescription = board?.board.description || ''; this.openSheet('board');
  }
  private async saveBoard(): Promise<void> {
    try {
      const board = await this.boardStore().save(this.boardEditorWorkspace, this.boardEditorId, this.boardTitle, this.boardDescription);
      this.boardSelection = this.boardEditorWorkspace + '/' + board.id; this.selected = ''; this.sheetOpen = false; await this.reload();
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
    const key = this.entryKey(entry), rect = this.rect(key), x = rect.x + rect.width / 2 + event.offsetX,
      y = rect.y + rect.height / 2 + event.offsetY;
    const target = this.layouts().findIndex((candidate: PanelRect) => x >= candidate.x && x < candidate.x + candidate.width && y >= candidate.y && y < candidate.y + candidate.height);
    const current = this.visible().findIndex((item: PanelEntry) => this.entryKey(item) === key);
    if (target === current || x < 0 || x > this.boardWidth || y < 0) { return; }
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
            Checkbox().select(!!this.pinEntry && this.boardFor(key).board.items.some((item) => referenceKey(item) === this.entryKey(this.pinEntry!)))
              .onChange((present: boolean) => { if (this.pinEntry && present !== this.boardFor(key).board.items.some((item) => referenceKey(item) === this.entryKey(this.pinEntry!))) { this.pinOnBoard(this.boardFor(key), this.pinEntry, present); } })
            Text(this.boardFor(key).board.title).fontSize(16).layoutWeight(1)
          }.width('100%')
        }, (key: string) => key)
        Button(t('新建看板')).attributeModifier(Btn.tonal).onClick(() => { this.editBoard(); })
      }.padding(24).width('100%')
    }.height('100%').width('100%').align(Alignment.TopStart)
  }
  @Builder private task() { if (this.taskEntry) { PanelTaskPanel({ entry: this.taskEntry }) } }
  @Builder private sheet() {
    if (this.sheetKind === 'connection') { this.connection() }
    else if (this.sheetKind === 'board') { this.boardEditor() }
    else if (this.sheetKind === 'pin') { this.pinPicker() }
    else if (this.sheetKind === 'task') { this.task() }
  }
  @Builder private collectionMenu() {
    Menu() {
      MenuItem({ content: this.removed ? t('返回') : t('已移除') }).onClick(() => { this.removed = !this.removed; this.selected = ''; })
    }
  }
  private tabTitle(key: string): string { return key ? this.boardFor(key).board.title : t('全部卡片'); }
  @Builder private boardTab(key: string) {
    Button(this.tabTitle(key)).type(ButtonType.Normal).height(36).padding({ left: 14, right: 14 }).borderRadius(18)
      .fontSize(14).labelStyle({ maxLines: 1 }).backgroundColor(this.boardSelection === key ? this.appearance.accent : $r('app.color.surface_variant'))
      .fontColor(this.boardSelection === key ? this.appearance.onAccent : $r('app.color.text_primary'))
      .accessibilityText(this.tabTitle(key) + (this.boardSelection === key ? t('，已选中') : ''))
      .onClick(() => { this.error = ''; this.boardSelection = key; this.selected = ''; this.removed = false; })
  }
  @Builder private detail(key: string) {
    Scroll() {
      Column({ space: 16 }) {
        this.card(key, true)
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
      }.width('100%').padding({ bottom: 20 }).alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).width('100%').align(Alignment.TopStart)
  }
  build() {
    Column({ space: 10 }) {
      Row({ space: 4 }) {
        Stack({ alignContent: Alignment.End }) {
          List({ space: 8, scroller: this.boardScroller }) {
            ListItem() { this.boardTab('') }
            ForEach(this.boards.filter((entry: BoardEntry) => !entry.board.archived).map((entry: BoardEntry) => this.boardKey(entry)), (key: string) => {
              ListItem() { this.boardTab(key) }
            }, (key: string) => key)
          }.listDirection(Axis.Horizontal).height(40).width('100%').scrollBar(BarState.Off).onAreaChange(() => this.revealBoard())
          Row().width(12).height(40).linearGradient({ angle: 90, colors: [[gradientColor($r('app.color.page_background'), 0), 0], [gradientColor($r('app.color.page_background'), 1), 1]] }).hitTestBehavior(HitTestMode.None)
        }.layoutWeight(1)
        IconButton({ icon: $r('sys.symbol.gearshape'), label: t('看板管理'), compId: 'life-board-manage', diameter: 36, iconSize: 18,
          onTap: () => this.editBoard(this.currentBoard()) })
        IconButton({ icon: $r('sys.symbol.plus'), label: t('创建卡片'), compId: 'life-panel-create', diameter: 36, iconSize: 18,
          disabled: !this.app.ready || this.app.busy || this.creating, onTap: () => { this.createCard(); } })
        Button({ type: ButtonType.Circle }) { Text('⋯').fontSize(24).fontColor($r('app.color.text_primary')) }
          .width(36).height(36).backgroundColor(Color.Transparent).accessibilityText(t('更多操作')).bindMenu(this.collectionMenu())
      }.width('100%')
      if (this.error) { Banner({ text: this.error }) }
      if (this.removed) { Text(t('已移除')).fontSize(14).width('100%') }
      if (this.currentBoard() && !this.selected && this.currentBoard()!.board.description) {
        Text(this.currentBoard()!.board.description).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').maxLines(2)
      }
      if (this.selected && this.visible().some((entry: PanelEntry) => this.entryKey(entry) === this.selected)) {
        Button(t('返回卡片列表')).attributeModifier(Btn.textSmall).onClick(() => { this.selected = ''; })
        ForEach(this.visible().filter((entry: PanelEntry) => this.entryKey(entry) === this.selected), (entry: PanelEntry) => {
          this.detail(this.entryKey(entry))
        }, (entry: PanelEntry) => this.entryKey(entry))
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
            if (!this.visible().length) {
              Column({ space: 12 }) {
                Text(t('把关心的事情放在这里')).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                Text(t('让 Tinybot 创建指标、清单或趋势卡片。支持手动刷新，应用在前台时会更新到期数据。')).fontSize(14).fontColor($r('app.color.text_secondary'))
              }.width('100%').padding({ top: 40 })
            } else {
              Stack({ alignContent: Alignment.TopStart }) {
                ForEach(this.visible().map((entry: PanelEntry) => this.entryKey(entry)), (key: string) => {
                  Column() { this.card(key) }
                    .width(this.rect(key).width).onAreaChange((_old: Area, area: Area) => this.measured(key, area))
                    .position({ x: this.rect(key).x, y: this.rect(key).y })
                    .translate({ x: this.dragging === key ? this.dragX : 0, y: this.dragging === key ? this.dragY : 0 })
                    .zIndex(this.dragging === key ? 10 : 0)
                    .gesture(GestureGroup(GestureMode.Sequence, LongPressGesture({ repeat: false, duration: 450 }),
                      PanGesture().onActionStart(() => { if (this.currentBoard()) { this.dragging = key; } })
                        .onActionUpdate((event: GestureEvent) => { if (this.dragging) { this.dragX = event.offsetX; this.dragY = event.offsetY; } })
                        .onActionEnd((event: GestureEvent) => { if (this.dragging) { this.dropCard(this.entryFor(key), 0, event); } })
                    ).onCancel(() => { this.dragging = ''; this.dragX = 0; this.dragY = 0; }))
                }, (key: string) => key + ':' + this.entryFor(key).panel.configRevision)
              }.width('100%').height(this.boardHeight())
            }
          }.id('life-panel-list').width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }.layoutWeight(1).width('100%').onRefreshing(async () => {
          try { await this.refreshAll(); } finally { this.refreshing = false; }
        })
      }
    }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .bindSheet($$this.sheetOpen, this.sheet(), { title: { title: this.sheetTitle() }, detents: [SheetSize.LARGE], onDisappear: () => this.detailChanged() })
      .onAreaChange((_old: Area, area: Area) => { this.boardWidth = Math.max(160, Number(area.width) - 32); })
  }
}
