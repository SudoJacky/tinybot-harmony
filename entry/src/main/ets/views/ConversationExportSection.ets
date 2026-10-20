import { AppearanceStyle } from '../common/AppearanceStyle';
import { ConversationSection } from '../model/ConversationExport';
import { MarkdownSpan, markdownSpans } from '../model/Markdown';
import { Attachments } from '../services/Attachments';
import { DataViewCard } from './DataViewCard';
import { providerLogo, monochromeProviderLogo } from '../common/ProviderBrand';

// A synchronous, fully expanded export view: no lazy rows, scroll containers,
// deferred Markdown batches, controls, or offscreen visibility placeholders.
@Component
export struct ConversationExportSection {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  section: ConversationSection = { kind: 'text', text: '', user: false };
  private textSize(): number {
    return this.section.kind === 'title' ? 24 : this.section.kind === 'heading' ? 21 - Math.min(4, this.section.block?.level || 1) :
      this.section.kind === 'role' || this.section.kind === 'footer' || this.section.kind === 'attachment' ? 13 : 16;
  }
  @Builder
  prose(value: string) {
    Text() {
      ForEach(markdownSpans(value), (span: MarkdownSpan) => {
        Span(span.text).fontWeight(span.kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(span.kind === 'code' ? 'monospace' : this.appearance.fontFamily)
          .decoration({ type: span.kind === 'strike' ? TextDecorationType.LineThrough : TextDecorationType.None })
      })
    }.fontFamily(this.appearance.fontFamily).fontSize(this.textSize()).lineHeight(this.textSize() * 1.65)
      .fontColor($r('app.color.text_primary')).width('100%').wordBreak(WordBreak.BREAK_ALL)
  }
  @Builder
  body() {
    Column() {
      if (this.section.kind === 'data-view') {
        DataViewCard({ content: this.section.text, snapshotMode: true })
      } else if (this.section.kind === 'attachment-image') {
        Image('file://' + Attachments.path(this.section.attachment!)).syncLoad(true).width('100%')
          .height(this.section.imageRatio ? Math.min(1800, Math.max(160, 328 * this.section.imageRatio)) : 240).objectFit(ImageFit.Contain)
        Text(this.section.text).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      } else if (this.section.kind === 'image') {
        Image(this.section.block!.rows[0][1]).syncLoad(true).width('100%').height(240).objectFit(ImageFit.Contain)
      } else if (this.section.kind === 'rule') {
        Divider().color($r('app.color.divider')).margin({ top: 5, bottom: 5 })
      } else if (this.section.kind === 'code') {
        Text(this.section.text).fontFamily('monospace').fontSize(13).lineHeight(21).width('100%')
          .fontColor($r('app.color.text_primary')).wordBreak(WordBreak.BREAK_ALL).padding(10)
          .backgroundColor($r('app.color.surface_variant')).borderRadius(8)
      } else if (this.section.kind === 'table') {
        Row() {
          ForEach(this.section.block!.rows[0], (cell: string) => {
            Column() { this.prose(cell) }.layoutWeight(1).padding(4)
          })
        }.width('100%').alignItems(VerticalAlign.Top).padding(4).border({ width: 0.5, color: $r('app.color.divider') })
      } else if (this.section.kind === 'role' && !this.section.user) {
        Row({ space: 7 }) {
          Image($r('app.media.tinybot')).syncLoad(true).width(22).height(22)
          Text('Tinybot').fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('AI').fontSize(10).fontColor($r('app.color.text_tertiary'))
        }.width('100%').padding({ top: 14, bottom: 4 })
        if (this.section.provider || this.section.model) {
          Row({ space: 6 }) {
            if (providerLogo(this.section.providerPreset || '')) {
              Image(providerLogo(this.section.providerPreset || '')).syncLoad(true).width(14).height(14)
                .fillColor(monochromeProviderLogo(this.section.providerPreset || '') ? $r('app.color.text_secondary') : undefined)
            }
            Text([this.section.provider, this.section.model].filter((value: string | undefined) => !!value).join(' · '))
              .fontFamily(this.appearance.fontFamily).fontSize(11).lineHeight(17).fontColor($r('app.color.text_secondary'))
              .layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
          }.width('100%').padding({ bottom: 8 })
        }
      } else if (this.section.kind === 'title') {
        Row({ space: 10 }) {
          Image($r('app.media.tinybot')).syncLoad(true).width(32).height(32)
          Column({ space: 2 }) {
            Text('Tinybot').fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
            Text(this.section.text).fontFamily(this.appearance.fontFamily).fontSize(21).lineHeight(29)
              .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ top: 14, bottom: 20 })
        Divider().color($r('app.color.divider'))
      } else if (this.section.kind === 'role' || this.section.kind === 'footer') {
        Text(this.section.text).fontFamily(this.appearance.fontFamily).fontSize(this.textSize()).lineHeight(this.textSize() * 1.65)
          .fontWeight(this.section.kind === 'footer' ? FontWeight.Normal : FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).width('100%')
          .textAlign(this.section.kind === 'footer' ? TextAlign.Center : TextAlign.Start)
          .padding({ top: this.section.kind === 'role' ? 12 : 8, bottom: 6 })
      } else {
        this.prose((this.section.kind === 'list' ? (this.section.block?.rows[0][0] || '•') + ' ' : '') + this.section.text)
      }
    }.width('100%')
  }
  build() {
    Column() {
      if (this.section.user) {
        Row() {
          Column() { this.body() }.width('88%').padding({ left: 14, right: 14, top: 3, bottom: 3 })
            .backgroundColor(this.appearance.userBubble)
            .borderRadius({ topLeft: this.section.bubbleStart ? 18 : 0, topRight: this.section.bubbleStart ? 18 : 0,
              bottomLeft: this.section.bubbleEnd ? 18 : 0, bottomRight: this.section.bubbleEnd ? 5 : 0 })
        }.width('100%').justifyContent(FlexAlign.End)
      } else { this.body() }
    }.width(360).padding({ left: 16, right: 16,
      top: this.section.bubbleStart ? 16 : this.section.user ? 0 : 4,
      bottom: this.section.bubbleEnd ? 16 : this.section.user ? 0 : 4 })
      .backgroundColor($r('app.color.page_background'))
  }
}
