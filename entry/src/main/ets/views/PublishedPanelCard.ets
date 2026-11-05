import { common } from '@kit.AbilityKit';
import { PublishedPanel } from '../model/PublishedPanel';
import { PanelRecord } from '../model/LifePanel';
import { LifePanels } from '../services/LifePanels';
import { LifeBoards } from '../services/LifeBoards';
import { PanelChanges } from '../services/PanelChanges';
import { Diagnostics } from '../model/Diagnostics';
import { LifePanelCard } from './LifePanelCard';
import { Btn } from '../common/Theme';
import { t } from '../model/I18n';
import { PanelTarget, BoardEntry, referenceKey } from '../model/LifeBoard';
@Component
export struct PublishedPanelCard {
  @Prop reference: PublishedPanel;
  @State private panel: PanelRecord | undefined = undefined;
  @State private title: string = '';
  @State private error: string = '';
  @State private pinOpen: boolean = false;
  @State private boards: BoardEntry[] = [];
  @State private boardTitle: string = '';
  private mounted: boolean = false;
  private unsubscribe?: () => void;
  aboutToAppear(): void { this.mounted = true; this.reload(); this.unsubscribe = PanelChanges.subscribe(() => this.reload()); }
  aboutToDisappear(): void { this.mounted = false; this.unsubscribe?.(); }
  private async reload(): Promise<void> {
    try {
      const root = (this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir, target = this.reference.target;
      if (target.panelId) {
        const panel = await new LifePanels(root).repository(target.workspaceId).get(target.panelId); if (this.mounted) { this.panel = panel; }
      } else {
        const board = await new LifeBoards(root).get(target.workspaceId, target.boardId!); if (this.mounted) { this.title = board.title; }
      }
      if (this.mounted) { this.error = ''; }
      if (this.pinOpen) { this.boards = await new LifeBoards(root).list(); }
    } catch (error) { if (this.mounted) { this.error = (error as Error).message; } Diagnostics.log('error', 'life-panel', 'action_failed', {}, error as Error); }
  }
  private async pin(board?: BoardEntry, present: boolean = true): Promise<void> {
    try {
      const root = (this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir, store = new LifeBoards(root), target = this.reference.target;
      const chosen = board || { workspaceId: target.workspaceId, board: await store.save(target.workspaceId, '', this.boardTitle, '') };
      await store.pin(chosen.workspaceId, chosen.board.id, { workspaceId: target.workspaceId, panelId: target.panelId! }, present);
      this.boardTitle = ''; this.boards = await store.list(); this.error = '';
    } catch (error) { this.error = (error as Error).message; }
  }
  @Builder private boardPicker() {
    Scroll() {
      Column({ space: 14 }) {
        ForEach(this.boards.filter((entry: BoardEntry) => !entry.board.archived), (entry: BoardEntry) => {
          Row({ space: 12 }) {
            Checkbox().select(entry.board.items.some((item) => referenceKey(item) === this.reference.target.workspaceId + '/' + this.reference.target.panelId))
              .onChange((present: boolean) => { if (present !== entry.board.items.some((item) => referenceKey(item) === this.reference.target.workspaceId + '/' + this.reference.target.panelId)) { this.pin(entry, present); } })
            Text(entry.board.title).fontSize(16).layoutWeight(1)
          }.width('100%')
        }, (entry: BoardEntry) => entry.workspaceId + '/' + entry.board.id)
        TextInput({ text: this.boardTitle, placeholder: t('看板名称') }).maxLength(80).onChange((value: string) => { this.boardTitle = value; })
        Button(t('新建看板')).attributeModifier(Btn.tonal).enabled(!!this.boardTitle.trim()).onClick(() => { this.pin(); })
        if (this.error) { Text(this.error).fontColor($r('app.color.danger')).fontSize(12) }
      }.width('100%').padding(24)
    }.width('100%').height('100%')
  }
  private open(): void {
    const target: PanelTarget = { workspaceId: this.reference.target.workspaceId, panelId: this.reference.target.panelId, boardId: this.reference.target.boardId, request: Date.now() };
    AppStorage.setOrCreate('tinybot.life-panel.target', JSON.stringify(target));
  }
  build() {
    Column({ space: 8 }) {
      if (this.panel) {
        Column() { LifePanelCard({ panel: this.panel, interactive: false, timestamp: 'Life Panel', onOpen: () => this.open() }) }.height(220).width('100%')
      }
      Button(t('打开 Life Panel：{0}', [this.panel?.definition.title || this.title || this.reference.title])).attributeModifier(Btn.tonal).onClick(() => this.open())
      if (this.reference.target.panelId) {
        Button(t('固定到看板')).attributeModifier(Btn.tonal).onClick(() => { this.pinOpen = true; this.reload(); })
      }
      if (this.error) { Text(this.error).fontSize(12).fontColor($r('app.color.danger')) }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .bindSheet($$this.pinOpen, this.boardPicker(), { title: { title: t('固定到看板') }, detents: [SheetSize.LARGE] })
  }
}
