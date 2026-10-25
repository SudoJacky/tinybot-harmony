import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { thoughtTail } from '../model/ProcessPresentation';
import { Motion } from '../common/Theme';
import { DisclosureState } from '../viewmodel/DisclosureState';
import { ThinkingLine } from '../common/Widgets';
import { AgentStepViewModel } from '../viewmodel/SessionViewModels';

// A thought is a sibling of tool calls, folded by default inside the turn process.
@Component
export struct ThinkingDisclosure {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  // The step is observed directly so reasoning deltas repaint this line without
  // rebuilding the whole message; the parent only changes when the row appears.
  @ObjectLink step: AgentStepViewModel;
  @Prop identity: string = '';
  @Prop streaming: boolean = false;
  @ObjectLink disclosure: DisclosureState;
  onInspect: () => void = () => {};
  private lineScroller: Scroller = new Scroller();

  private lineText(): string {
    return this.streaming ? thoughtTail(this.step.reasoningContent, 160)
      : this.step.reasoningContent.replace(/\s+/g, ' ');
  }

  private scrollLineEnd(): void {
    try { this.lineScroller.scrollEdge(Edge.End); } catch (error) { /* laid out later */ }
  }

  build() {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        ThinkingLine({ label: this.streaming ? t('正在思考') : t('已思考'), working: this.streaming, compact: true })
        if (!this.disclosure.open) {
          if (this.streaming) {
            // A live single-line ticker: the newest words stay at the right edge
            // while the line keeps advancing with the reasoning stream.
            Scroll(this.lineScroller) {
              Text(this.lineText()).fontFamily(this.appearance.fontFamily).id('thinking-line-' + this.identity)
                .fontSize(12).maxLines(1).fontColor($r('app.color.text_tertiary'))
                .padding({ right: 12 }).height(20)
                .onAreaChange((_old: Area, _new: Area) => { this.scrollLineEnd(); })
            }
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
            .layoutWeight(1).height(20).clip(true)
          } else {
            Text(this.lineText()).fontFamily(this.appearance.fontFamily)
              .fontSize(12).maxLines(1).layoutWeight(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('app.color.text_tertiary'))
          }
        } else {
          Blank()
        }
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
        }.width(16).height(16).rotate({ angle: this.disclosure.open ? 180 : 0 })
          .animation({ duration: Motion.medium, curve: Motion.standard })
      }.id('thinking-toggle-' + this.identity).width('100%').height(32)
      .accessibilityText((this.disclosure.open ? t('收起') : t('展开')) + ' ' + (this.streaming ? t('正在思考') : t('已思考')))
      .onClick(() => {
        this.onInspect();
        this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard }, () => {
          this.disclosure.open = !this.disclosure.open;
          if (this.disclosure.open && this.disclosure.limit === 0) { this.disclosure.limit = 4000; }
        });
      })
      if (this.disclosure.open) {
        Text(this.step.reasoningContent.slice(0, this.disclosure.limit)).fontFamily(this.appearance.fontFamily).id('thinking-content-' + this.identity)
          .width('100%').fontSize(13).lineHeight(21).fontColor($r('app.color.text_tertiary')).copyOption(CopyOptions.LocalDevice)
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -3 }))
            .animation({ duration: Motion.medium, curve: Motion.standard }))
        if (this.step.reasoningContent.length > this.disclosure.limit) {
          Text(t('展开更多')).fontFamily(this.appearance.fontFamily).id('thinking-more-' + this.identity).fontSize(12)
            .fontColor(this.appearance.accent).height(32)
            .onClick(() => { this.onInspect(); this.disclosure.limit += 4000; })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
