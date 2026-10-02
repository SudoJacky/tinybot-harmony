import { t } from '../model/I18n';
import { ToolPreview, toolPreview, prettyToolText } from '../model/ToolPresentation';
import { DisclosureState } from '../viewmodel/DisclosureState';

// Expands in place under its tool row, capped to a few lines so opening it never floods the conversation.
@Component
export struct ToolDetails {
  @ObjectLink disclosure: DisclosureState;
  @Prop identity: string = '';
  @Prop name: string = '';
  @Prop argumentsText: string = '';
  @Prop output: string = '';
  @Prop status: string = '';
  onInspect: () => void = () => {};

  private preview(): ToolPreview { return toolPreview(this.name, this.argumentsText, this.output, this.status); }
  private longest(): string {
    const preview = this.preview();
    return [preview.content, preview.before, preview.after].reduce((a: string, b: string) => a.length >= b.length ? a : b, '');
  }
  private hasMore(): boolean {
    const text = this.longest();
    return this.disclosure.limit === 0 ? text.length > 400 || text.split('\n').length > 6 : text.length > this.disclosure.limit;
  }

  @Builder
  previewText(value: string, lines: number, color: ResourceColor) {
    if (this.disclosure.limit === 0) {
      Text(value).fontSize(13).lineHeight(20).width('100%').maxLines(lines)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(color)
    } else {
      Text(value.slice(0, this.disclosure.limit)).fontSize(13).lineHeight(20).width('100%')
        .fontColor(color).copyOption(CopyOptions.LocalDevice)
    }
  }

  @Builder
  rawText(value: string) {
    Scroll() {
      Text(value).fontSize(12).lineHeight(19).fontFamily('monospace')
        .fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.LocalDevice)
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto).width('100%').align(Alignment.Start)
  }

  build() {
    Column({ space: 6 }) {
      if (this.preview().path) {
        Text(this.preview().path).fontSize(12).lineHeight(18).width('100%')
          .fontColor($r('app.color.text_tertiary')).copyOption(CopyOptions.LocalDevice)
      }
      if (this.preview().changed) {
        Text(t('替换前')).fontSize(12).fontColor($r('app.color.danger'))
        this.previewText(this.preview().before || t('空文本'), 6, $r('app.color.text_secondary'))
        Text(t('替换后')).fontSize(12).fontColor($r('app.color.accent'))
        this.previewText(this.preview().after || t('空文本'), 6, $r('app.color.text_primary'))
      } else if (this.output.length > 0) {
        this.previewText(this.preview().content || t('无内容'), 8,
          this.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
      }
      if (this.preview().truncated) {
        Text(t('工具仅返回了部分内容')).fontSize(12).fontColor($r('app.color.text_tertiary'))
      }
      Row({ space: 16 }) {
        if (this.hasMore()) {
          Text(t('展开更多')).id('tool-more-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
            .onClick(() => { this.onInspect(); this.disclosure.limit += 4000; })
        }
        if (this.disclosure.limit > 0) {
          Text(t('收起')).id('tool-less-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
            .onClick(() => { this.onInspect(); this.disclosure.limit = 0; })
        }
        Row({ space: 4 }) {
          Text(t('原始记录')).fontSize(12).fontColor($r('app.color.text_tertiary'))
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.text_tertiary')])
            .rotate({ angle: this.disclosure.rawOpen ? 180 : 0 })
        }.id('tool-raw-' + this.identity).height(44)
        .accessibilityText((this.disclosure.rawOpen ? t('收起') : t('展开')) + ' ' + t('原始记录'))
        .onClick(() => { this.onInspect(); this.disclosure.rawOpen = !this.disclosure.rawOpen; })
      }
      if (this.disclosure.rawOpen) {
        Text(t('参数')).fontSize(12).fontColor($r('app.color.text_tertiary'))
        this.rawText(prettyToolText(this.argumentsText).slice(0, this.disclosure.rawLimit))
        Text(t('结果')).fontSize(12).fontColor($r('app.color.text_tertiary'))
        this.rawText(prettyToolText(this.output).slice(0, this.disclosure.rawLimit))
        Row({ space: 16 }) {
          if (Math.max(prettyToolText(this.argumentsText).length, prettyToolText(this.output).length) > this.disclosure.rawLimit) {
            Text(t('展开更多')).id('tool-raw-more-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
              .onClick(() => { this.onInspect(); this.disclosure.rawLimit += 4000; })
          }
          if (this.disclosure.rawLimit > 2000) {
            Text(t('收起')).id('tool-raw-less-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
              .onClick(() => { this.onInspect(); this.disclosure.rawLimit = 2000; })
          }
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 4 })
  }
}
