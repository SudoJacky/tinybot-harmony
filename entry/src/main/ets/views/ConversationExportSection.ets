import { text } from '@kit.ArkGraphics2D';
import { ConversationSection } from '../model/ConversationExport';
import { ConversationImageStyle, ConversationImageTheme, conversationImageTheme } from '../model/ConversationImageStyle';
import { MarkdownSpan, markdownSpans } from '../model/Markdown';
import { Attachments } from '../services/Attachments';
import { DataViewCard } from './DataViewCard';
import { providerLogo, monochromeProviderLogo } from '../common/ProviderBrand';

export const CONVERSATION_EXPORT_WIDTH = 360;
const BUBBLE_WIDTH_RATIO = 0.88;
const BUBBLE_PADDING = 14;
const ANSWER_INSET = 14;
const EDITORIAL_LATIN_FAMILY = 'TinybotEditorialLatin';
const EDITORIAL_HAN_FAMILY = 'TinybotEditorialHan';
const HAN_TITLE_RUN = /([\u3000-\u303f\u3400-\u9fff\uf900-\ufaff\uff00-\uffef\u{20000}-\u{323af}]+)/u;
let editorialFontsLoaded = false;

export function loadEditorialTitleFonts(): void {
  if (editorialFontsLoaded) { return; }
  const fonts = text.FontCollection.getGlobalInstance();
  fonts.loadFontSync(EDITORIAL_LATIN_FAMILY, $rawfile('fonts/tinybot-editorial-latin.ttf'));
  fonts.loadFontSync(EDITORIAL_HAN_FAMILY, $rawfile('fonts/tinybot-editorial-han.ttf'));
  editorialFontsLoaded = true;
}

// A synchronous, fully expanded export view: no lazy rows, scroll containers,
// deferred Markdown batches, controls, or offscreen visibility placeholders.
@Component
export struct ConversationExportSection {
  section: ConversationSection = { kind: 'text', text: '', user: false };
  style: ConversationImageStyle = ConversationImageStyle.Editorial;

  private theme(): ConversationImageTheme { return conversationImageTheme(this.style); }
  private userBubble(): boolean { return this.style === ConversationImageStyle.Transcript && this.section.user; }
  private lead(): boolean { return this.section.lead === true && this.style !== ConversationImageStyle.Transcript; }
  private answerRule(): boolean {
    return this.style === ConversationImageStyle.Poster && !this.section.user &&
      this.section.kind !== 'title' && this.section.kind !== 'footer';
  }
  private pageContentWidth(): number { return CONVERSATION_EXPORT_WIDTH - 2 * this.theme().pagePadding; }
  private bubbleWidth(): number { return Math.round(this.pageContentWidth() * BUBBLE_WIDTH_RATIO); }

  private textSize(): number {
    if (this.lead()) { return 19; }
    if (this.section.kind === 'heading') { return 21 - Math.min(4, this.section.block?.level || 1); }
    if (this.section.kind === 'attachment') { return 13; }
    return this.style === ConversationImageStyle.Transcript ? 15 : 16;
  }
  private attachmentHeight(): number {
    const width = this.userBubble() ? this.bubbleWidth() - 2 * BUBBLE_PADDING :
      this.pageContentWidth() - (this.answerRule() ? ANSWER_INSET : 0);
    return Math.min(1800, Math.max(1, width * this.section.imageRatio!));
  }
  private topSpacing(): number {
    if (this.userBubble()) { return this.section.bubbleStart ? 12 : 0; }
    return this.section.kind === 'role' || this.section.kind === 'footer' ? 14 : 0;
  }
  @Builder
  prose(value: string) {
    Text() {
      ForEach(markdownSpans(value), (span: MarkdownSpan) => {
        Span(span.text).fontWeight(this.lead() || span.kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(span.kind === 'code' ? 'monospace' : 'sans-serif')
          .decoration({ type: span.kind === 'strike' ? TextDecorationType.LineThrough : TextDecorationType.None })
      })
    }.fontSize(this.textSize()).lineHeight(this.textSize() * 1.6)
      .fontWeight(this.section.kind === 'heading' ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.lead() ? this.theme().accent : this.theme().ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
  }
  @Builder
  body() {
    Column() {
      if (this.section.kind === 'data-view') {
        DataViewCard({ content: this.section.text, snapshotMode: true })
      } else if (this.section.kind === 'attachment-image') {
        Image('file://' + Attachments.path(this.section.attachment!)).syncLoad(true).width('100%')
          .height(this.attachmentHeight()).objectFit(ImageFit.Contain).interpolation(ImageInterpolation.High)
        Text(this.section.text).fontSize(12).fontColor(this.theme().muted).width('100%')
      } else if (this.section.kind === 'image') {
        Image(this.section.block!.rows[0][1]).syncLoad(true).width('100%').height(240)
          .objectFit(ImageFit.Contain).interpolation(ImageInterpolation.High)
      } else if (this.section.kind === 'rule') {
        Divider().color(this.theme().rule).margin({ top: 5, bottom: 5 })
      } else if (this.section.kind === 'code') {
        Text(this.section.text).fontFamily('monospace').fontSize(13).lineHeight(21).width('100%')
          .fontColor(this.theme().ink).wordBreak(WordBreak.BREAK_ALL).padding(10)
          .backgroundColor(this.theme().surface).borderRadius(8)
      } else if (this.section.kind === 'table') {
        Row() {
          ForEach(this.section.block!.rows[0], (cell: string) => {
            Column() { this.prose(cell) }.layoutWeight(1).padding(4)
          })
        }.width('100%').alignItems(VerticalAlign.Top).padding(4).border({ width: 0.5, color: this.theme().rule })
      } else if (this.section.kind === 'role' && !this.section.user) {
        Text('Tinybot · AI').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.theme().muted).width('100%')
        if (this.section.provider || this.section.model) {
          Row({ space: 6 }) {
            if (providerLogo(this.section.providerPreset || '')) {
              Image(providerLogo(this.section.providerPreset || '')).syncLoad(true).width(14).height(14)
                .fillColor(monochromeProviderLogo(this.section.providerPreset || '') ? this.theme().muted : undefined)
            }
            Text([this.section.provider, this.section.model].filter((value: string | undefined) => !!value).join(' · '))
              .fontSize(11).lineHeight(17).fontColor(this.theme().muted)
              .layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
          }.width('100%').padding({ top: 3 })
        }
      } else if (this.section.kind === 'title') {
        Row({ space: 5 }) {
          Image($r('app.media.tinybot')).syncLoad(true).width(20).height(20)
          Text('Tinybot').fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.theme().ink)
        }.width('100%').padding({ top: 20, bottom: 12 })
        Text() {
          if (this.style === ConversationImageStyle.Editorial) {
            // A missing glyph in ArkUI's first family can fall back to the system before trying the next custom family.
            ForEach(this.section.text.split(HAN_TITLE_RUN), (run: string, index: number) => {
              if (run.length > 0) {
                Span(run).fontFamily(index % 2 === 0 ? EDITORIAL_LATIN_FAMILY : EDITORIAL_HAN_FAMILY)
              }
            }, (_run: string, index: number) => String(index))
          } else {
            Span(this.section.text)
          }
        }.fontFamily('sans-serif').fontSize(this.theme().titleSize)
          .lineHeight(Math.ceil(this.theme().titleSize * (this.style === ConversationImageStyle.Editorial ? 1.38 : 1.28)))
          .fontWeight(this.style === ConversationImageStyle.Editorial ? FontWeight.Normal : FontWeight.Bold)
          .fontColor(this.theme().ink).width('100%').wordBreak(WordBreak.BREAK_WORD).padding({ bottom: 15 })
        Divider().color(this.style === ConversationImageStyle.Poster ? this.theme().accent : this.theme().rule)
      } else if (this.section.kind === 'role') {
        Text(this.section.text).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.theme().muted).width('100%')
          .padding({ top: this.userBubble() ? 7 : 0 })
      } else if (this.section.kind === 'footer') {
        Divider().color(this.theme().rule)
        Text(this.section.text).fontSize(12).lineHeight(18).fontColor(this.theme().muted).width('100%')
          .padding({ top: 10, bottom: 14 })
      } else {
        this.prose((this.section.kind === 'list' ? (this.section.block?.rows[0][0] || '•') + ' ' : '') + this.section.text)
      }
    }.width('100%')
  }
  build() {
    Column() {
      if (this.userBubble()) {
        Row() {
          Column() { this.body() }.width(this.bubbleWidth())
            .padding({ left: BUBBLE_PADDING, right: BUBBLE_PADDING, top: 3, bottom: this.section.bubbleEnd ? 9 : 3 })
            .backgroundColor(this.theme().surface)
            .borderRadius({ topLeft: this.section.bubbleStart ? 18 : 0, topRight: this.section.bubbleStart ? 18 : 0,
              bottomLeft: this.section.bubbleEnd ? 18 : 0, bottomRight: this.section.bubbleEnd ? 5 : 0 })
        }.width('100%').justifyContent(FlexAlign.End)
      } else {
        Column() { this.body() }.width('100%')
          .padding({ left: this.answerRule() ? ANSWER_INSET : 0, top: 4, bottom: 4 })
          .border({ width: { left: this.answerRule() ? 2 : 0 }, color: this.theme().accent })
      }
    }.width(CONVERSATION_EXPORT_WIDTH)
      .padding({ left: this.theme().pagePadding, right: this.theme().pagePadding, top: this.topSpacing() })
      .backgroundColor(this.theme().page)
  }
}
