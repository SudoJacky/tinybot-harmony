import { t } from '../model/I18n';
import { FormField } from '../model/RichArtifacts';
import { ToolApproval } from '../services/ToolApproval';
import { Btn, Font, Radius, Space, Styles } from '../common/Theme';
import { IconBadge } from '../common/Widgets';

// The assistant paused to ask for structured input; sits above the composer like the tool approval card.
@Component
export struct InputFormCard {
  @ObjectLink approval: ToolApproval;
  @State private values: string[] = [];
  private set(index: number, value: string): void { const next = this.values.slice(); next[index] = value; this.values = next; }
  private chosen(index: number): string[] { return (this.values[index] || '').split('\n').filter((item) => item.length > 0); }
  private toggle(index: number, option: string): void {
    const selected = this.chosen(index);
    this.set(index, selected.includes(option) ? selected.filter((item) => item !== option).join('\n') : selected.concat([option]).join('\n'));
  }

  @Builder
  optionChip(field: FormField, index: number, option: string) {
    Row({ space: 4 }) {
      if (this.chosen(index).includes(option)) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13).fontColor([$r('app.color.on_accent_container')])
      }
      Text(option).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.chosen(index).includes(option) ? $r('app.color.on_accent_container') : $r('app.color.text_primary'))
    }
    .height(34).padding({ left: 14, right: 14 }).borderRadius(17).margin({ right: Space.sm, bottom: Space.sm })
    .backgroundColor(this.chosen(index).includes(option) ? $r('app.color.accent_container') : $r('app.color.surface_variant'))
    .accessibilityText(option + (this.chosen(index).includes(option) ? t("，已选中") : ''))
    .onClick(() => { if (field.type === 'select') { this.set(index, option); } else { this.toggle(index, option); } })
  }

  build() {
    Column({ space: Space.md }) {
      Row({ space: Space.sm }) {
        IconBadge({ icon: $r('sys.symbol.questionmark_circle'), diameter: 32 })
        Column({ space: 2 }) {
          Text(t("助手需要你补充信息")).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          Text(this.approval.form?.title || '').fontSize(15).fontWeight(FontWeight.Medium).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Scroll() {
        Column({ space: 14 }) {
          ForEach(this.approval.form?.fields || [], (field: FormField, index: number) => {
            Column({ space: 6 }) {
              Text() {
                Span(field.label)
                if (field.required) { Span(' *').fontColor($r('app.color.danger')) }
              }.fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
              if (field.type === 'select' || field.type === 'multiselect') {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(field.options || [], (option: string) => { this.optionChip(field, index, option) },
                    (option: string) => option)
                }.width('100%').margin({ bottom: -Space.sm })
              } else {
                TextInput({ text: this.values[index] || '', placeholder: field.type === 'number' ? t("请输入数字") : t("请输入") })
                  .id('form-field-' + index).attributeModifier(Styles.input).height(44)
                  .type(field.type === 'password' ? InputType.Password : field.type === 'number' ? InputType.NUMBER_DECIMAL : InputType.Normal)
                  .maxLength(2000).onChange((value) => this.set(index, value))
              }
            }.width('100%').alignItems(HorizontalAlign.Start)
          })
        }.width('100%')
      }.constraintSize({ maxHeight: 280 }).width('100%').scrollBar(BarState.Off).align(Alignment.TopStart)
      if (this.approval.formError) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(14).fontColor([$r('app.color.danger')])
          Text(this.approval.formError).fontSize(Font.caption).layoutWeight(1).fontColor($r('app.color.danger'))
        }.width('100%')
      }
      Row({ space: Space.sm }) {
        Button(t("不回答")).id('cancel-form').attributeModifier(Btn.plainSmall).height(40).layoutWeight(1)
          .onClick(() => { this.values = []; this.approval.cancelForm(); })
        Button(t("提交并继续")).id('submit-form').attributeModifier(Btn.primarySmall).height(40).layoutWeight(1)
          .onClick(() => { this.approval.submit(this.values); if (!this.approval.form) { this.values = []; } })
      }.width('100%')
    }.width('100%').padding(Space.md).backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
    .border({ width: 1, color: $r('app.color.accent_container') })
    .shadow({ radius: 16, color: '#1A000000', offsetY: 2 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 24 })).animation({ duration: 200 }))
  }
}
