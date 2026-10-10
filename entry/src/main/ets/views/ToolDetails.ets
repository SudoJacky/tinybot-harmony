import { t } from '../model/I18n';
import { prettyToolText, toolTitle, toolStatusLabel } from '../model/ToolPresentation';
import { DetailRow, DetailSection, ToolDetailContent, compactDetailValue, detailPages, toolDetailContent } from '../model/ToolDetailContent';
import { DisclosureState } from '../viewmodel/DisclosureState';
import { Attachments } from '../services/Attachments';
import { DataViewCard } from './DataViewCard';

@Component
struct ReceiptSection {
  @Prop section: DetailSection;
  @Prop compact: boolean = false;

  private color(): ResourceColor {
    return this.section.style === 'error' || this.section.style === 'removed' ? $r('app.color.danger') :
      this.section.style === 'added' ? $r('app.color.accent') : $r('app.color.text_primary');
  }
  private surfaceColor(): ResourceColor {
    return this.section.style === 'error' || this.section.style === 'removed' ? $r('app.color.danger_container') :
      this.section.style === 'added' ? $r('app.color.accent_container') : $r('app.color.surface_variant');
  }
  build() {
    Column({ space: 6 }) {
      Text(this.section.title).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.color())
        .maxLines(this.compact ? 2 : 8).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
      if (this.section.body.length > 0) {
        Text(this.compact ? this.section.body.slice(0, 900) : this.section.body)
          .fontSize(13).lineHeight(20).width('100%').fontColor(this.color())
          .fontFamily(['code', 'added', 'removed'].includes(this.section.style) ? 'monospace' : '')
          .maxLines(this.compact ? 5 : 10000).textOverflow({ overflow: TextOverflow.Ellipsis })
          .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
      }
      ForEach(this.section.rows.slice(0, this.compact ? 2 : this.section.rows.length).map((_row: DetailRow, index: number) => index), (index: number) => {
        Column({ space: 3 }) {
          Text(this.section.rows[index].label).fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
            .maxLines(this.compact ? 2 : 10000).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
          if (this.section.rows[index].value.length > 0) {
            Text(this.compact ? compactDetailValue(this.section.rows[index].value).slice(0, 240) : this.section.rows[index].value).fontSize(13).lineHeight(20).width('100%')
              .fontColor($r('app.color.text_primary')).maxLines(this.compact ? 2 : 10000)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 4 })
      }, (index: number) => index.toString())
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).borderRadius(10).backgroundColor(this.surfaceColor())
  }
}

// One receipt renderer for chat, Team and nested calls. Full details live in a bounded, paged sheet.
@Component
export struct ToolDetails {
  @ObjectLink disclosure: DisclosureState;
  @Prop identity: string = '';
  @Prop @Watch('refresh') name: string = '';
  @Prop @Watch('refresh') argumentsText: string = '';
  @Prop @Watch('refresh') output: string = '';
  @Prop @Watch('refresh') status: string = '';
  onInspect: () => void = () => {};
  @State private expanded: boolean = false;
  @State private content: ToolDetailContent = toolDetailContent('', '', '', '');
  @State private pages: DetailSection[] = [];
  @State private imageError: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void { this.refresh(); }
  refresh(): void {
    this.imageError = false;
    this.content = toolDetailContent(this.name, this.argumentsText, this.output, this.status);
    this.updatePages();
  }
  private updatePages(): void {
    let sections = this.content.sections;
    if (this.disclosure.detailTab === 'logs') { sections = this.content.logs; }
    if (this.disclosure.detailTab === 'input') { sections = this.content.inputs; }
    if (this.disclosure.detailTab === 'raw') {
      sections = [
        { title: t('参数'), body: prettyToolText(this.argumentsText), style: 'code', rows: [] },
        { title: t('结果'), body: prettyToolText(this.output), style: 'code', rows: [] }
      ];
    }
    this.pages = detailPages(sections);
    this.disclosure.detailPage = Math.max(0, Math.min(this.disclosure.detailPage, this.pages.length - 1));
  }
  private select(tab: string): void {
    this.onInspect();
    if (this.disclosure.detailTab !== tab) { this.disclosure.detailPage = 0; }
    this.disclosure.detailTab = tab;
    this.updatePages(); this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }
  private inspect(tab: string): void { this.select(tab); this.expanded = true; }
  private page(delta: number): void {
    this.disclosure.detailPage += delta; this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  @Builder
  picture() {
    if (this.content.image) {
      if (this.imageError) {
        Text(t('图片文件不可用')).fontSize(12).fontColor($r('app.color.text_secondary'))
      } else {
        Image(Attachments.path(this.content.image)).width('100%').height(220).objectFit(ImageFit.Contain)
          .borderRadius(10).accessibilityText(this.content.image.name).onError(() => { this.imageError = true; })
      }
    }
  }

  @Builder
  tab(label: string, value: string) {
    Button(label).type(ButtonType.Normal).fontSize(13).height(44).layoutWeight(1).borderRadius(8)
      .padding({ left: 4, right: 4 })
      .backgroundColor(this.disclosure.detailTab === value ? $r('app.color.accent_container') : Color.Transparent)
      .fontColor(this.disclosure.detailTab === value ? $r('app.color.on_accent_container') : $r('app.color.text_secondary'))
      .id('tool-tab-' + value + '-' + this.identity).onClick(() => this.select(value))
  }

  @Builder
  viewer() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text(toolTitle(this.name)).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(toolStatusLabel(this.status)).fontSize(12)
            .fontColor(this.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(t('关闭')).height(44).fontSize(13).backgroundColor(Color.Transparent).fontColor($r('app.color.accent'))
          .id('tool-detail-close-' + this.identity).onClick(() => { this.expanded = false; })
      }.width('100%')
      Row({ space: 4 }) {
        this.tab(t('结果'), 'result')
        this.tab(t('参数'), 'input')
        if (this.content.logs.length) { this.tab(t('日志'), 'logs') }
        this.tab(t('原始记录'), 'raw')
      }.width('100%')
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.content.path) {
            Text(this.content.path).fontSize(12).lineHeight(18).width('100%').fontColor($r('app.color.text_secondary'))
              .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
          }
          if (this.disclosure.detailTab === 'result' && this.disclosure.detailPage === 0) {
            this.picture()
            if (this.name === 'publish_data_view' && this.status === 'complete') { DataViewCard({ content: this.output }) }
          }
          if (this.pages.length > 0) { ReceiptSection({ section: this.pages[this.disclosure.detailPage] }) }
          ForEach(this.content.notices, (notice: string) => {
            Text(notice).fontSize(12).lineHeight(18).fontColor($r('app.color.warning')).width('100%')
          })
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 16 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
      if (this.pages.length > 1) {
        Row({ space: 8 }) {
          Button(t('上一页')).height(44).fontSize(13).enabled(this.disclosure.detailPage > 0)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.accent'))
            .id('tool-detail-prev-' + this.identity).onClick(() => this.page(-1))
          Text((this.disclosure.detailPage + 1) + ' / ' + this.pages.length).layoutWeight(1).textAlign(TextAlign.Center)
            .fontSize(12).fontColor($r('app.color.text_tertiary'))
          Button(t('下一页')).height(44).fontSize(13).enabled(this.disclosure.detailPage < this.pages.length - 1)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.accent'))
            .id('tool-detail-next-' + this.identity).onClick(() => this.page(1))
        }.width('100%')
      }
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 12, bottom: 24 })
  }

  build() {
    Column({ space: 8 }) {
      if (this.content.path) {
        Text(this.content.path).fontSize(12).lineHeight(18).maxLines(2).width('100%')
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.LocalDevice)
      }
      if (this.content.summary) {
        Text(this.content.summary).fontSize(12).fontColor($r('app.color.text_tertiary'))
      }
      this.picture()
      ForEach(this.content.sections.slice(0, 2).map((_section: DetailSection, index: number) => index), (index: number) => {
        ReceiptSection({ section: this.content.sections[index], compact: true })
      }, (index: number) => index.toString())
      if (this.content.notices.length) {
        Text(this.content.notices[0]).fontSize(12).fontColor($r('app.color.warning'))
      }
      Text(t('仅预览本次返回内容，详情可分页查看')).fontSize(11).fontColor($r('app.color.text_tertiary'))
      Row({ space: 16 }) {
        Text(t('查看详情')).id('tool-more-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
          .onClick(() => this.inspect('result'))
        Text(t('参数')).id('tool-input-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
          .onClick(() => this.inspect('input'))
        if (this.content.logs.length) {
          Text(t('日志')).id('tool-logs-' + this.identity).fontSize(12).fontColor($r('app.color.accent')).height(44)
            .onClick(() => this.inspect('logs'))
        }
        Text(t('原始记录')).id('tool-raw-' + this.identity).fontSize(12).fontColor($r('app.color.text_tertiary')).height(44)
          .onClick(() => this.inspect('raw'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 4 })
    .bindSheet($$this.expanded, this.viewer(), { height: '90%', showClose: false, dragBar: true,
      backgroundColor: $r('app.color.page_background') })
  }
}
