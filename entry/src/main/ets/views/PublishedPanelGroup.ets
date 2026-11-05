import { PublishedPanel } from '../model/PublishedPanel';
import { PanelTarget } from '../model/LifeBoard';
import { t } from '../model/I18n';
import { Btn } from '../common/Theme';
@Component
export struct PublishedPanelGroup {
  @Prop references: PublishedPanel[] = [];
  @State private choosing: boolean = false;
  private open(reference: PublishedPanel): void {
    this.choosing = false;
    const target: PanelTarget = { workspaceId: reference.target.workspaceId, panelId: reference.target.panelId, boardId: reference.target.boardId, request: Date.now() };
    AppStorage.setOrCreate('tinybot.life-panel.target', JSON.stringify(target));
  }
  @Builder private picker() {
    List({ space: 8 }) {
      ForEach(this.references, (reference: PublishedPanel) => {
        ListItem() { Button(reference.title).attributeModifier(Btn.tonal).width('100%').onClick(() => this.open(reference)) }
      }, (reference: PublishedPanel) => reference.key)
    }.width('100%').height('100%').padding(20)
  }
  build() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(24).fontColor([$r('app.color.accent')])
      Column({ space: 4 }) {
        Text(t('本轮更新了 {0} 个卡片与看板', [this.references.length])).fontSize(14).fontWeight(FontWeight.Medium)
        Text(this.references.map((reference: PublishedPanel) => reference.title).join(' · ')).fontSize(12)
          .fontColor($r('app.color.text_secondary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button(t('打开')).attributeModifier(Btn.textSmall).onClick(() => { this.choosing = true; })
    }.width('100%').padding(14).backgroundColor($r('app.color.surface_variant')).borderRadius(12)
      .bindSheet($$this.choosing, this.picker(), { title: { title: t('生活看板') }, detents: [SheetSize.MEDIUM, SheetSize.LARGE] })
  }
}
