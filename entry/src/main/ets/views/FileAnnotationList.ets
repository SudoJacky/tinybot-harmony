import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Radius, Space, Styles } from '../common/Theme';
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
  @State private saveError: string = '';
  @State private saving: boolean = false;

  private toggleExpanded(): void {
    if (this.editing || this.saving) { return; }
    this.expanded = !this.expanded;
  }

  private edit(item: FileAnnotation): void {
    if (!this.editable || this.disabled || this.editing || this.saving) { return; }
    this.comment = item.comment;
    this.saveError = '';
    this.editing = item.id;
  }

  private cancelEdit(): void {
    if (!this.saving) { this.editing = ''; }
  }

  private async change(id: string, comment?: string): Promise<void> {
    if (!this.editable || this.disabled || this.saving) { return; }
    if (comment === undefined ? !!this.editing : this.editing !== id || !comment.trim()) { return; }
    this.saveError = '';
    this.saving = true;
    try {
      await this.onChange(id, comment);
      this.editing = '';
    } catch (error) {
      const message = (error as Error).message;
      if (comment === undefined) {
        this.getUIContext().getPromptAction().showToast({ message: message });
      } else {
        this.saveError = message;
      }
    } finally { this.saving = false; }
  }

  @Builder
  private entry(item: FileAnnotation, index: number) {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        Text(String(index + 1)).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
          .fontWeight(FontWeight.Medium).width(24).height(24).borderRadius(12).textAlign(TextAlign.Center)
          .backgroundColor(this.appearance.accentContainer).fontColor(this.appearance.onAccentContainer)
        Column({ space: Space.xs }) {
          Text(item.path.split('/').pop()).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
            .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).accessibilityDescription(item.path)
          Text(item.location).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
            .fontColor($r('app.color.text_secondary')).width('100%').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.editable && this.editing !== item.id) {
          IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t('编辑批注'), diameter: 32, iconSize: 15,
            disabled: this.disabled || this.saving || !!this.editing, onTap: () => this.edit(item) })
          IconButton({ icon: $r('sys.symbol.trash'), label: t('删除批注'), diameter: 32, iconSize: 15,
            disabled: this.disabled || this.saving || !!this.editing, onTap: () => this.change(item.id) })
        }
      }.width('100%')
      if (item.excerpt && item.excerpt !== item.location) {
        Text(item.excerpt).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(18)
          .fontColor($r('app.color.text_secondary')).width('100%').maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).padding(Space.sm)
          .backgroundColor($r('app.color.surface_variant')).borderRadius(Radius.sm)
      }
      if (this.editing === item.id) {
        TextArea({ text: this.comment, placeholder: t('描述修改或提出问题…') }).attributeModifier(Styles.area)
          .fontFamily(this.appearance.fontFamily).maxLength(MAX_ANNOTATION_COMMENT).showCounter(true)
          .height(92).width('100%').enabled(!this.saving && !this.disabled)
          .onChange((text) => { this.comment = text; })
        if (this.saveError) {
          Text(this.saveError).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
            .fontColor($r('app.color.danger')).width('100%')
        }
        Row({ space: Space.sm }) {
          Button(t('取消')).attributeModifier(Btn.textSmall).enabled(!this.saving).onClick(() => this.cancelEdit())
          Button(this.saving ? t('保存中…') : t('保存')).attributeModifier(Btn.primarySmall)
            .enabled(!this.saving && !this.disabled && this.comment.trim().length > 0)
            .onClick(() => this.change(item.id, this.comment))
        }.justifyContent(FlexAlign.End).width('100%')
      } else {
        Text(item.comment).fontFamily(this.appearance.fontFamily).fontSize(Font.small).lineHeight(21)
          .fontColor($r('app.color.text_primary')).width('100%')
      }
    }.width('100%').padding(Space.md).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface')).borderRadius(Radius.md)
      .border({ width: 0.5, color: $r('app.color.divider') })
  }

  build() {
    Column({ space: Space.sm }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: Space.sm }) {
          Text(t('{0} 条批注', [this.items.length])).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
            .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(10).fontColor([$r('app.color.text_secondary')])
            .rotate({ angle: this.expanded ? 90 : 0 }).accessibilityLevel('no')
        }
      }.attributeModifier(Btn.tonalSmall).id(this.editable ? 'draft-file-annotations' : 'sent-file-annotations')
        .accessibilityText(t('{0} 条批注', [this.items.length]))
        .accessibilityDescription(this.expanded ? t('点按收起') : t('点按展开'))
        .enabled(!this.editing && !this.saving).onClick(() => this.toggleExpanded())
      if (this.expanded) {
        Scroll() {
          Column({ space: Space.xs }) {
            ForEach(this.items, (item: FileAnnotation, index: number) => {
              this.entry(item, index)
            }, (item: FileAnnotation, index: number) => item.id + ':' + index + ':' + item.comment)
          }.width('100%')
        }.constraintSize({ maxHeight: this.editing ? 268 : 238 }).scrollBar(BarState.Auto).width('100%')
      }
    }.alignItems(this.editable ? HorizontalAlign.Start : HorizontalAlign.End)
  }
}
