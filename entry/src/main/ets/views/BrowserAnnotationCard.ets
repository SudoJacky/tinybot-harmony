import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { BrowserPropertyChange } from '../model/BrowserAnnotation';
import { MAX_BROWSER_ANNOTATION_NOTE } from '../model/BrowserAnnotationContent';
import { Attachment } from '../model/Productivity';
import { t } from '../model/I18n';
import { Attachments } from '../services/Attachments';

@Component
export struct BrowserAnnotationCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop item: Attachment | undefined = undefined;
  @Prop editable: boolean = false;
  @Prop disabled: boolean = false;
  onPreview: () => void = () => {};
  onChange: (note?: string) => Promise<void> = async () => {};
  @State private editing: boolean = false;
  @State private saving: boolean = false;
  @State private note: string = '';

  private async save(note?: string): Promise<void> {
    if (this.saving || this.disabled) { return; }
    this.saving = true;
    try { await this.onChange(note); this.editing = false; }
    catch (error) { this.getUIContext().getPromptAction().showToast({ message: (error as Error).message }); }
    finally { this.saving = false; }
  }

  build() {
    if (this.item && this.item.browserAnnotation) {
      Column({ space: Space.xs }) {
        Row({ space: Space.sm }) {
          Button({ type: ButtonType.Normal }) {
            Image('file://' + Attachments.path(this.item!)).width('100%').height('100%').objectFit(ImageFit.Cover)
          }.width(36).height(30).padding(0).borderRadius(Radius.sm).clip(true)
            .backgroundColor($r('app.color.surface_variant')).accessibilityText(this.item.name).onClick(this.onPreview)
          if (this.item.browserAnnotation.element?.tag) {
            Text(this.item.browserAnnotation.element.tag).fontSize(Font.caption).fontWeight(FontWeight.Medium)
              .borderRadius(5).backgroundColor($r('app.color.surface_variant')).padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .maxLines(1).constraintSize({ maxWidth: 76 }).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('app.color.text_primary'))
          }
          Text(this.item.browserAnnotation.element?.label || this.item.browserAnnotation.element?.location ||
            this.item.browserAnnotation.title || this.item.browserAnnotation.url)
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
          if (this.editable) {
            IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t('编辑批注'), compId: 'edit-browser-annotation',
              iconSize: 15, disabled: this.disabled || this.saving,
              onTap: () => { this.note = this.item?.browserAnnotation?.note || ''; this.editing = true; } })
            IconButton({ icon: $r('sys.symbol.trash'), label: t('删除批注'), compId: 'remove-browser-annotation',
              iconSize: 15, disabled: this.disabled || this.saving, onTap: () => this.save() })
          }
        }.width('100%')
        if (this.editing) {
          TextArea({ text: this.note, placeholder: t('描述这些修改…') }).id('edit-browser-annotation-note')
            .height(64).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
            .maxLength(MAX_BROWSER_ANNOTATION_NOTE).enabled(!this.saving)
            .onChange((note: string) => { this.note = note; })
          Row({ space: Space.xs }) {
            Button(t('取消')).attributeModifier(Btn.textSmall).enabled(!this.saving).onClick(() => { this.editing = false; })
            Button(t('保存')).attributeModifier(Btn.primarySmall).id('save-browser-annotation-note')
              .enabled(!this.saving && !this.disabled).onClick(() => this.save(this.note))
          }.width('100%').justifyContent(FlexAlign.End)
        } else if (this.item.browserAnnotation.note) {
          Text(this.item.browserAnnotation.note).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
            .fontColor($r('app.color.text_primary')).width('100%').copyOption(CopyOptions.LocalDevice)
        }
        ForEach(this.item.browserAnnotation.changes || [], (change: BrowserPropertyChange) => {
          Text() {
            Span(change.property + ': ').fontColor($r('app.color.text_secondary'))
            Span(change.before + '  →  ' + change.after).fontColor($r('app.color.text_primary'))
          }.fontFamily(this.appearance.fontFamily).fontSize(Font.small).width('100%')
        }, (change: BrowserPropertyChange) => change.property)
      }.id(this.editable ? 'draft-browser-annotation-' + this.item.id : 'browser-annotation-' + this.item.id)
        .alignItems(HorizontalAlign.Start).width('100%').padding(Space.sm)
        .borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
        .border({ width: 0.5, color: $r('app.color.divider') })
    }
  }
}
