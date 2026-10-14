import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { thoughtTail } from '../model/ProcessPresentation';
import { Motion } from '../common/Theme';
import { DisclosureState } from '../viewmodel/DisclosureState';
import { ThinkingLine } from '../common/Widgets';

// A compact preview follows live thought; explicit reading choices survive completion.
@Component
export struct ThinkingDisclosure {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop content: string = '';
  @Prop identity: string = '';
  @Prop streaming: boolean = false;
  @ObjectLink disclosure: DisclosureState;
  onInspect: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        ThinkingLine({ label: this.streaming ? t('正在思考') : t('已思考'), working: this.streaming, compact: true })
        if (!this.disclosure.open) {
          Text(this.streaming ? thoughtTail(this.content) : this.content.replace(/\s+/g, ' ')).fontFamily(this.appearance.fontFamily)
            .fontSize(12).maxLines(1).layoutWeight(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_tertiary'))
        } else {
          Blank()
        }
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
        }.width(16).height(16).rotate({ angle: this.disclosure.open ? 180 : 0 })
          .animation({ duration: Motion.medium, curve: Motion.standard })
      }.id('thinking-toggle-' + this.identity).width('100%').height(44)
      .accessibilityText((this.disclosure.open ? t('收起') : t('展开')) + ' ' + (this.streaming ? t('正在思考') : t('已思考')))
      .onClick(() => {
        this.onInspect();
        this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard }, () => {
          this.disclosure.open = !this.disclosure.open;
          if (this.disclosure.open && this.disclosure.limit === 0) { this.disclosure.limit = 4000; }
        });
      })
      if (this.disclosure.open) {
        Text(this.content.slice(0, this.disclosure.limit)).fontFamily(this.appearance.fontFamily).id('thinking-content-' + this.identity)
          .width('100%').fontSize(13).lineHeight(21)
          .fontColor($r('app.color.text_tertiary')).copyOption(CopyOptions.LocalDevice)
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -3 }))
            .animation({ duration: Motion.medium, curve: Motion.standard }))
        Row({ space: 16 }) {
          if (this.content.length > this.disclosure.limit) {
            Text(t('展开更多')).fontFamily(this.appearance.fontFamily).id('thinking-more-' + this.identity).fontSize(12).fontColor(this.appearance.accent).height(44)
              .onClick(() => { this.onInspect(); this.disclosure.limit += 4000; })
          }
          Text(t('收起')).fontFamily(this.appearance.fontFamily).id('thinking-less-' + this.identity).fontSize(12).fontColor(this.appearance.accent).height(44)
            .onClick(() => { this.onInspect(); this.disclosure.open = false; })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
