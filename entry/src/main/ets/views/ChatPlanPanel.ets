import { t } from '../model/I18n';
import { PlanItem } from '../model/RichArtifacts';
import { PlanProgressViewModel } from '../viewmodel/PlanProgressViewModel';
import { Font, Motion, Radius, Space } from '../common/Theme';

interface PlanStepInput { item: PlanItem; running: boolean; }

@Component
export struct ChatPlanPanel {
  @ObjectLink plan: PlanProgressViewModel;

  private title(): string {
    if (this.plan.error) { return t('计划读取失败'); }
    if (this.plan.finished) { return t('计划已完成'); }
    return this.plan.running ? t('任务计划') : t('计划未完成');
  }

  private toggle(): void {
    // Animate only an explicit disclosure action, never streamed progress updates.
    this.getUIContext().animateTo({ duration: 180, curve: Motion.standard }, () => {
      this.plan.expanded = !this.plan.expanded;
    });
  }

  @Builder
  stepRow(input: PlanStepInput) {
    Row({ space: 10 }) {
      if (input.item.status === 'completed') {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(16).fontColor([$r('app.color.accent')])
      } else if (input.item.status === 'in_progress' && input.running) {
        LoadingProgress().width(16).height(16).color($r('app.color.accent'))
      } else {
        SymbolGlyph($r('sys.symbol.circle')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
      }
      Text(input.item.step).fontSize(13).lineHeight(19).layoutWeight(1)
        .fontWeight(input.item.status === 'in_progress' ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(input.item.status === 'completed' ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
        .decoration({ type: input.item.status === 'completed' ? TextDecorationType.LineThrough : TextDecorationType.None })
    }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 7, bottom: 7 })
  }

  build() {
    if (this.plan.available) {
      Column() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: Space.sm }) {
            if (this.plan.running) {
              LoadingProgress().width(16).height(16).color($r('app.color.accent'))
            } else {
              SymbolGlyph(this.plan.finished ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.list_bullet'))
                .fontSize(16).fontColor([$r('app.color.accent')])
            }
            Column({ space: 2 }) {
              Text(this.title()).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              if (this.plan.currentStep) {
                Text(this.plan.currentStep).id('chat-plan-current-step').fontSize(13).fontWeight(FontWeight.Medium)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
              }
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (!this.plan.error) {
              Text(this.plan.completed + ' / ' + this.plan.steps.length).id('chat-plan-count')
                .fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
            }
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.plan.expanded ? 180 : 0 })
          }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12, top: 6, bottom: 6 })
        }.id('chat-plan-toggle').width('100%').backgroundColor(Color.Transparent).borderRadius(Radius.md)
        .clickEffect(Motion.press).onClick(() => this.toggle())
        .accessibilityText(this.title() + '，' + this.plan.currentStep + '，' + this.plan.completed + ' / ' + this.plan.steps.length +
          '，' + (this.plan.expanded ? t('收起计划') : t('展开计划')))
        if (this.plan.error) {
          Text(this.plan.error).id('chat-plan-error').fontSize(12).fontColor($r('app.color.danger'))
            .width('100%').padding({ left: 12, right: 12, bottom: 10 }).copyOption(CopyOptions.LocalDevice)
        } else if (this.plan.expanded) {
          Scroll() {
            Column() {
              if (this.plan.explanation) {
                Text(this.plan.explanation).fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary'))
                  .width('100%').padding({ bottom: 8 }).copyOption(CopyOptions.LocalDevice)
              }
              ForEach(this.plan.steps.map((_item, index: number) => index), (index: number) => {
                this.stepRow({ item: this.plan.steps[index], running: this.plan.running })
              }, (index: number) => index.toString())
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 12, right: 12, bottom: 8 })
          }.id('chat-plan-steps').width('100%').constraintSize({ maxHeight: 200 })
            .scrollBar(BarState.Auto).align(Alignment.TopStart)
        }
      }.id('chat-plan-panel').width('100%').borderRadius(Radius.md).clip(true)
        .backgroundColor($r('app.color.surface'))
        .border({ width: 0.5, color: $r('app.color.divider') })
    }
  }
}
