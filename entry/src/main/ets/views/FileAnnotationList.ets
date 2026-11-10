import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { FileAnnotation, MAX_ANNOTATION_COMMENT } from '../model/FileAnnotation';
import { t } from '../model/I18n';

@Component
export struct FileAnnotationList {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop items: FileAnnotation[] = [];
  @Prop editable: boolean = false;
  @Prop disabled: boolean = false;
  onChange: (id: string, comment?: string) => Promise<void> = async () => {};
  @State private expanded: boolean = false;
  @State private editing: string = '';
  @State private comment: string = '';
  @State private saving: boolean = false;

  private async change(id: string, comment?: string): Promise<void> {
    if (this.saving || this.disabled) { return; }
    this.saving = true;
    try {
      await this.onChange(id, comment);
      this.editing = '';
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: (error as Error).message });
    } finally { this.saving = false; }
  }

  @Builder
  private entry(item: FileAnnotation, index: number) {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text(String(index + 1)).fontSize(11).fontWeight(FontWeight.Medium).width(22).height(22)
          .borderRadius(11).textAlign(TextAlign.Center).backgroundColor(this.appearance.accent).fontColor(this.appearance.onAccent)
        Column({ space: 2 }) {
          Text(item.path.split('/').pop()).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.location).fontSize(11).fontColor($r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.editable) {
          IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t('编辑批注'), diameter: 32, iconSize: 15,
            disabled: this.disabled || this.saving, onTap: () => { this.editing = item.id; this.comment = item.comment; } })
          IconButton({ icon: $r('sys.symbol.trash'), label: t('删除批注'), diameter: 32, iconSize: 15,
            disabled: this.disabled || this.saving, onTap: () => this.change(item.id) })
        }
      }.width('100%')
      if (this.editing === item.id) {
        TextArea({ text: this.comment }).fontFamily(this.appearance.fontFamily).maxLength(MAX_ANNOTATION_COMMENT).height(70)
          .onChange((text) => { this.comment = text; })
        Row({ space: Space.sm }) {
          Button(t('取消')).attributeModifier(Btn.tonalSmall).onClick(() => { this.editing = ''; })
          Button(t('保存')).attributeModifier(Btn.primarySmall).enabled(!this.saving && !this.disabled && this.comment.trim().length > 0)
            .onClick(() => this.change(item.id, this.comment))
        }.justifyContent(FlexAlign.End).width('100%')
      } else {
        Text(item.comment).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_primary')).width('100%')
      }
    }.padding(Space.sm).width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: Space.xs }) {
      if (this.expanded) {
        Scroll() {
          Column() {
            ForEach(this.items, (item: FileAnnotation, index: number) => {
              this.entry(item, index)
            }, (item: FileAnnotation) => item.id + ':' + item.comment)
          }.width('100%')
        }.constraintSize({ maxHeight: 238 }).scrollBar(BarState.Auto).width('100%')
          .backgroundColor($r('app.color.surface')).borderRadius(Radius.md)
          .border({ width: 0.5, color: $r('app.color.divider') })
      }
      Button(t('{0} 条批注', [this.items.length])).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.tonalSmall)
        .id(this.editable ? 'draft-file-annotations' : 'sent-file-annotations')
        .onClick(() => { this.expanded = !this.expanded; this.editing = ''; })
    }.alignItems(this.editable ? HorizontalAlign.Start : HorizontalAlign.End)
  }
}
