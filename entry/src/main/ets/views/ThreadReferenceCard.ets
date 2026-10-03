import { t } from '../model/I18n';
import { ThreadReference } from '../model/ThreadReferences';
import { IconButton } from '../common/Widgets';
import { Radius, Space } from '../common/Theme';

@Component
export struct ThreadReferenceCard {
  @Prop reference: ThreadReference;
  removable: boolean = false;
  disabled: boolean = false;
  onRemove: () => void = () => {};
  @State private previewing: boolean = false;

  @Builder
  preview() {
    Scroll() {
      Column({ space: Space.md }) {
        Text(this.reference.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(t('引用的是选择时的文字快照，不含附件和工具记录。')).fontSize(13).fontColor($r('app.color.text_secondary'))
        if (this.reference.truncated) {
          Text(t('内容较长，仅引用最近部分。')).fontSize(13).fontColor($r('app.color.text_secondary'))
        }
        Text(this.reference.content).fontSize(14).lineHeight(22).copyOption(CopyOptions.LocalDevice)
          .fontColor($r('app.color.text_primary')).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.page)
    }.width('100%').height('100%').align(Alignment.Top)
  }

  build() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.ellipsis_message')).fontSize(18).fontColor([$r('app.color.accent')])
      Column({ space: 2 }) {
        Text(this.reference.title).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'))
        Text(this.reference.truncated ? t('会话引用 · 最近部分') : t('会话引用 · 文字快照'))
          .fontSize(11).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.removable) {
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('移除会话引用'), compId: 'remove-reference-' + this.reference.threadId,
          diameter: 32, iconSize: 12, disabled: this.disabled, onTap: this.onRemove })
      }
    }.id('reference-' + this.reference.threadId).width('100%').padding({ left: 10, right: 6, top: 6, bottom: 6 })
    .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
    .onClick(() => { this.previewing = true; })
    .bindSheet($$this.previewing, this.preview(), { title: { title: t('会话引用') }, detents: [SheetSize.LARGE], dragBar: true,
      backgroundColor: $r('app.color.page_background') })
  }
}
