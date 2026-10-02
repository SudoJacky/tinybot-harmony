import { t } from '../model/I18n';
import { thoughtTail } from '../model/ProcessPresentation';
import { Motion } from '../common/Theme';
import { DisclosureState } from '../viewmodel/DisclosureState';

// A compact preview follows live thought; explicit reading choices survive completion.
@Component
export struct ThinkingDisclosure {
  @Prop content: string = '';
  @Prop identity: string = '';
  @Prop streaming: boolean = false;
  @ObjectLink disclosure: DisclosureState;
  onInspect: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.lightbulb')).fontSize(13).fontColor([$r('app.color.text_tertiary')])
        Text(this.streaming ? t('正在思考') : t('已思考')).fontSize(13).flexShrink(0)
          .fontColor($r('app.color.text_secondary'))
        if (!this.disclosure.open) {
          Text(this.streaming ? thoughtTail(this.content) : this.content.replace(/\s+/g, ' '))
            .fontSize(12).maxLines(1).layoutWeight(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_tertiary'))
        } else {
          Blank()
        }
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.disclosure.open ? 180 : 0 })
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
        Text(this.content.slice(0, this.disclosure.limit)).id('thinking-content-' + this.identity)
          .width('100%').fontSize(13).lineHeight(21)
          .fontColor($r('app.color.text_tertiary')).copyOption(CopyOptions.LocalDevice)
        Row({ space: 16 }) {
          if (this.content.length > this.disclosure.limit) {
            Text(t('展开更多')).id('thinking-more-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
              .onClick(() => { this.onInspect(); this.disclosure.limit += 4000; })
          }
          Text(t('收起')).id('thinking-less-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
            .onClick(() => { this.onInspect(); this.disclosure.open = false; })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
