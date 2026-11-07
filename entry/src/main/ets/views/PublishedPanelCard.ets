import { common } from '@kit.AbilityKit';
import { PublishedPanel } from '../model/PublishedPanel';
import { PanelEntry } from '../model/LifePanel';
import { LifePanels } from '../services/LifePanels';
import { LifeBoards } from '../services/LifeBoards';
import { PanelChanges } from '../services/PanelChanges';
import { Diagnostics } from '../model/Diagnostics';
import { LifePanelCard } from './LifePanelCard';
import { Btn, Radius, systemInsets } from '../common/Theme';
import { t } from '../model/I18n';
import { PanelTarget, PanelReference, BoardEntry, referenceKey } from '../model/LifeBoard';
@Component
export struct PublishedPanelCard {
  @Prop @Watch('reload') reference: PublishedPanel;
  @State private entries: PanelEntry[] = [];
  @State private title: string = '';
  @State private boardEmpty: boolean = false;
  @State private error: string = '';
  @State private loading: boolean = true;
  @State private pinOpen: boolean = false;
  @State private boards: BoardEntry[] = [];
  @State private boardTitle: string = '';
  @State private pinError: string = '';
  @State private pinLoading: boolean = false;
  @State private pinSaving: boolean = false;
  @State private bottomInset: number = 0;
  private pinTarget?: PanelReference;
  private mounted: boolean = false;
  private generation: number = 0;
  private unsubscribe?: () => void;
  private root(): string { return (this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir; }
  private panels(): LifePanels { return new LifePanels(this.root()); }
  aboutToAppear(): void { this.mounted = true; this.reload(); this.unsubscribe = PanelChanges.subscribe(() => this.reload()); }
  aboutToDisappear(): void { this.mounted = false; this.generation++; this.unsubscribe?.(); }
  private report(error: Error): void {
    this.error = error.message;
    Diagnostics.log('error', 'life-panel', 'action_failed', {}, error);
  }
  private async reload(): Promise<void> {
    const generation = ++this.generation;
    try {
      const target = this.reference.target, panels = this.panels(), entries: PanelEntry[] = [];
      let title = '', boardEmpty = false;
      if (target.panelId) {
        entries.push({ workspaceId: target.workspaceId, panel: await panels.repository(target.workspaceId).get(target.panelId) });
      } else {
        const board = await new LifeBoards(this.root()).get(target.workspaceId, target.boardId!); title = board.title;
        boardEmpty = board.items.length === 0;
        for (const item of board.items) {
          if (this.reference.excludedPanelKeys?.includes(referenceKey(item))) { continue; }
          entries.push({ workspaceId: item.workspaceId, panel: await panels.repository(item.workspaceId).get(item.panelId) });
        }
      }
      if (!this.mounted || generation !== this.generation) { return; }
      this.entries = entries; this.title = title; this.boardEmpty = boardEmpty; this.error = '';
    } catch (error) { if (this.mounted && generation === this.generation) { this.report(error as Error); } }
    finally { if (this.mounted && generation === this.generation) { this.loading = false; } }
  }
  private async openPicker(entry: PanelEntry): Promise<void> {
    this.pinTarget = { workspaceId: entry.workspaceId, panelId: entry.panel.id };
    this.boardTitle = ''; this.pinError = ''; this.boards = []; this.pinLoading = true; this.pinOpen = true;
    try {
      this.bottomInset = (await systemInsets(this.getUIContext()))[1];
      this.boards = await new LifeBoards(this.root()).list();
    }
    catch (error) { this.pinError = (error as Error).message; Diagnostics.log('error', 'life-panel', 'action_failed', {}, error as Error); }
    finally { this.pinLoading = false; }
  }
  private async pin(board?: BoardEntry, present: boolean = true): Promise<void> {
    if (this.pinSaving || this.pinLoading || !this.pinTarget) { return; }
    this.pinSaving = true; this.pinError = '';
    const target = this.pinTarget, store = new LifeBoards(this.root());
    try {
      const chosen = board || { workspaceId: target.workspaceId, board: await store.save(target.workspaceId, '', this.boardTitle, '') };
      await store.pin(chosen.workspaceId, chosen.board.id, target, present);
      this.boardTitle = ''; this.boards = await store.list();
    } catch (error) {
      this.pinError = (error as Error).message;
      Diagnostics.log('error', 'life-panel', 'action_failed', {}, error as Error);
      // Re-read persisted membership after a failed write; keep the error visible.
      try { this.boards = await store.list(); }
      catch (refreshError) { this.pinError += '\n' + (refreshError as Error).message; }
    } finally { this.pinSaving = false; }
  }
  private board(key: string): BoardEntry { return this.boards.find((entry: BoardEntry) => entry.workspaceId + '/' + entry.board.id === key)!; }
  private pinned(key: string): boolean {
    return !!this.pinTarget && this.board(key).board.items.some((item) => referenceKey(item) === referenceKey(this.pinTarget!));
  }
  @Builder private boardPicker() {
    Scroll() {
      Column({ space: 14 }) {
        Text(t('可选择多个看板，勾选后立即保存。')).fontSize(12).fontColor($r('app.color.text_secondary'))
        if (this.pinLoading) { LoadingProgress().width(24).height(24) }
        ForEach(this.boards.filter((entry: BoardEntry) => !entry.board.archived).map((entry: BoardEntry) => entry.workspaceId + '/' + entry.board.id), (key: string) => {
          Row({ space: 12 }) {
            Checkbox().select(this.pinned(key)).enabled(!this.pinSaving && !this.pinLoading)
              .accessibilityText(this.board(key).board.title)
              .onChange((present: boolean) => { if (present !== this.pinned(key)) { this.pin(this.board(key), present); } })
            Text(this.board(key).board.title).fontSize(16).layoutWeight(1)
          }.width('100%').constraintSize({ minHeight: 48 })
        }, (key: string) => key)
        TextInput({ text: this.boardTitle, placeholder: t('看板名称') }).maxLength(80).enabled(!this.pinSaving && !this.pinLoading)
          .onChange((value: string) => { this.boardTitle = value; })
        Button(t('新建看板并固定')).attributeModifier(Btn.tonal).width('100%')
          .enabled(!!this.boardTitle.trim() && !this.pinSaving && !this.pinLoading).onClick(() => { this.pin(); })
        if (this.pinError) { Text(this.pinError).fontColor($r('app.color.danger')).fontSize(12) }
        Button(t('完成')).attributeModifier(Btn.text).enabled(!this.pinSaving && !this.pinLoading).onClick(() => { this.pinOpen = false; })
      }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 24 + this.bottomInset })
    }.width('100%').height('100%').align(Alignment.TopStart)
  }
  private open(target: PanelTarget): void {
    AppStorage.setOrCreate('tinybot.life-panel.target', JSON.stringify({ workspaceId: target.workspaceId, panelId: target.panelId, boardId: target.boardId, request: Date.now() } as PanelTarget));
  }
  // A configuration edit needs a new HTML storage capability. Data-only refreshes retain the mounted view.
  private entryKey(entry: PanelEntry): string { return entry.workspaceId + '/' + entry.panel.id + '/' + entry.panel.configRevision; }
  private entry(key: string): PanelEntry { return this.entries.find((entry: PanelEntry) => this.entryKey(entry) === key)!; }
  private runtimeError(key: string, message: string, revision: number): void {
    const entry = this.entry(key);
    this.panels().repository(entry.workspaceId).recordRuntimeError(entry.panel.id, revision, message).catch((error: Error) => this.report(error));
  }
  @Builder private preview(key: string) {
    Column({ space: 8 }) {
      LifePanelCard({ panel: this.entry(key).panel, interactive: false, showFooter: false, cardSize: 'M',
        busy: this.entry(key).panel.runs?.[0]?.status === 'running' && this.panels().repository(this.entry(key).workspaceId).isRefreshing(this.entry(key).panel.id),
        storage: this.panels().repository(this.entry(key).workspaceId).binding(this.entry(key).panel.id, this.entry(key).panel.configRevision),
        onRuntimeError: (message: string, revision: number) => this.runtimeError(key, message, revision),
        onOpen: () => this.open({ workspaceId: this.entry(key).workspaceId, panelId: this.entry(key).panel.id }) })
      Button(t('固定到看板')).attributeModifier(Btn.tonal).width('100%').id('pin-published-panel-' + this.entry(key).panel.id)
        .enabled(!this.entry(key).panel.archived && !this.pinSaving && !this.pinLoading).onClick(() => { this.openPicker(this.entry(key)); })
    }.width('100%')
  }
  build() {
    Column({ space: 12 }) {
      if (this.reference.target.boardId) {
        Button(this.title || this.reference.title).attributeModifier(Btn.text).onClick(() => this.open(this.reference.target))
      }
      if (this.loading) { LoadingProgress().width(24).height(24) }
      ForEach(this.entries.map((entry: PanelEntry) => this.entryKey(entry)), (key: string) => {
        this.preview(key)
      }, (key: string) => key)
      if (!this.loading && !this.error && this.reference.target.boardId && this.boardEmpty) {
        Text(t('此看板暂无卡片。')).fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      if (this.error) { Text(this.error).fontSize(12).fontColor($r('app.color.danger')) }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .bindSheet($$this.pinOpen, this.boardPicker(), { radius: Radius.sheet, title: { title: t('固定到看板') },
        detents: [SheetSize.LARGE], backgroundColor: $r('app.color.page_background'),
        onWillDismiss: () => { if (!this.pinSaving) { this.pinOpen = false; } } })
  }
}
