import { FileDiff } from '../model/FileDiff';
import { t } from '../model/I18n';
import { FileDiffCard } from './FileDiffCard';
import { Btn } from '../common/Theme';

@Component
export struct TurnChangesCard {
  @Prop changes: FileDiff[] = [];
  @State private expanded: boolean = false;
  @State private selected: string = '';
  @State private filePage: number = 0;
  @State private diffPage: number = 0;
  private visible(): FileDiff[] { return this.changes.slice(this.filePage * 10, (this.filePage + 1) * 10); }
  build() {
    Column({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Text(t('本轮修改 · {0} 个文件', [this.changes.length])).fontSize(13).layoutWeight(1).fontColor($r('app.color.text_primary'))
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).rotate({ angle: this.expanded ? 180 : 0 }).fontColor([$r('app.color.text_secondary')])
        }.width('100%')
      }.height(44).backgroundColor(Color.Transparent).onClick(() => { this.expanded = !this.expanded; })
      if (this.expanded) {
        Text(t('比较本轮首次修改前与最后成功写入的内容。')).fontSize(11).fontColor($r('app.color.text_tertiary')).width('100%')
        ForEach(this.visible(), (diff: FileDiff) => {
          Column({ space: 6 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Text(diff.path).fontSize(12).layoutWeight(1).maxLines(2).fontColor($r('app.color.text_primary'))
                Text('+' + diff.added).fontSize(12).fontColor($r('app.color.accent'))
                Text('−' + diff.removed).fontSize(12).fontColor($r('app.color.danger'))
              }.width('100%')
            }.constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent)
              .onClick(() => { this.selected = this.selected === diff.path ? '' : diff.path; this.diffPage = 0; })
            if (this.selected === diff.path) {
              FileDiffCard({ diff: diff, page: this.diffPage })
              if (diff.rows.length > 40) {
                Row({ space: 12 }) {
                  Button(t('上一页')).attributeModifier(Btn.textSmall).enabled(this.diffPage > 0).onClick(() => { this.diffPage--; })
                  Text((this.diffPage + 1) + ' / ' + Math.ceil(diff.rows.length / 40)).fontSize(12).fontColor($r('app.color.text_secondary'))
                  Button(t('下一页')).attributeModifier(Btn.textSmall).enabled((this.diffPage + 1) * 40 < diff.rows.length).onClick(() => { this.diffPage++; })
                }
              }
            }
          }.width('100%')
        }, (diff: FileDiff) => diff.path)
        if (this.changes.length > 10) {
          Row({ space: 12 }) {
            Button(t('上一页')).attributeModifier(Btn.textSmall).enabled(this.filePage > 0).onClick(() => { this.filePage--; this.selected = ''; })
            Text((this.filePage + 1) + ' / ' + Math.ceil(this.changes.length / 10)).fontSize(12).fontColor($r('app.color.text_secondary'))
            Button(t('下一页')).attributeModifier(Btn.textSmall).enabled((this.filePage + 1) * 10 < this.changes.length).onClick(() => { this.filePage++; this.selected = ''; })
          }
        }
      }
    }.width('100%').padding(10).borderRadius(12).backgroundColor($r('app.color.surface_variant'))
  }
}
