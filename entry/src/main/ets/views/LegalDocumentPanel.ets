import { PageStyles } from '../common/PageStyles';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Btn, Font, Space } from '../common/Theme';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Banner } from '../common/Widgets';
import { t } from '../model/I18n';
import { MarkdownView } from './MarkdownView';

interface LegalSection { title: string; content: string; }

@Component
export struct LegalDocumentPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @State private content: string = '';
  @State private error: string = '';
  @State private sections: LegalSection[] = [];
  @State private panelWidth: number = 0;
  @State private selected: number = 0;
  @State private showContents: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const resource = 'user-agreement.md';
      const bytes = context.resourceManager.getRawFileContentSync(resource);
      this.content = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
      if (!this.content.trim()) { throw new Error('Empty legal document: ' + resource); }
      this.sections = this.content.split(/(?=^## )/m).map((part: string, index: number): LegalSection => {
        return { title: index === 0 ? t('用户协议') : part.split('\n')[0].replace(/^##\s+/, ''), content: part };
      });
    } catch (error) {
      this.error = t('用户协议') + '：' + (error as Error).message;
    }
  }

  @Builder
  contents() {
    Scroll() {
      Column({ space: Space.xs }) {
        if (this.panelWidth >= 760) {
          Text(t('目录')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').padding(Space.md)
        }
        ForEach(this.sections, (section: LegalSection, index: number) => {
          Button(section.title).attributeModifier(Btn.text).id('legal-section-' + index)
            .fontSize(13).width('100%').constraintSize({ minHeight: 44 }).height('auto')
            .padding(Space.md).labelStyle({ maxLines: 3 }).align(Alignment.Start)
            .backgroundColor(this.selected === index ? this.appearance.accentContainer : Color.Transparent)
            .accessibilitySelected(this.selected === index)
            .onClick(() => { this.showContents = false; this.selected = index; this.scroller.scrollToIndex(index, true, ScrollAlign.START); })
        }, (_section: LegalSection, index: number) => String(index))
      }.width('100%').padding(Space.md)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }

  build() {
    Column() {
      if (this.panelWidth < 760 && this.sections.length > 1) {
        Button() {
          Row({ space: Space.sm }) {
            Text(t('目录')).fontSize(14).fontColor(this.appearance.accent)
            Text(this.sections[this.selected]?.title || '').fontSize(13).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([this.appearance.accent])
          }.width('100%')
        }.id('legal-open-contents').height(44).width('100%').padding({ left: Space.page, right: Space.page })
          .backgroundColor($r('app.color.page_background')).onClick(() => { this.showContents = true; })
          .bindSheet($$this.showContents, this.contents(), { title: { title: t('目录') },
            detents: [SheetSize.MEDIUM, SheetSize.LARGE], preferType: SheetType.BOTTOM,
            backgroundColor: $r('app.color.page_background'), showClose: true })
      }
      Row({ space: Space.md }) {
        if (this.panelWidth >= 760 && this.sections.length > 1) {
          Column() {
            this.contents()
          }.width(172).height('100%').align(Alignment.Top)
        }
        List({ scroller: this.scroller }) {
          if (this.error) {
            ListItem() { Banner({ text: this.error, compId: 'user-agreement-error' }) }
          } else {
            ForEach(this.sections, (section: LegalSection) => {
              ListItem() {
                MarkdownView({ content: section.content, fontSize: Font.body, selectable: true })
              }.padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.md })
            }, (_section: LegalSection, index: number) => String(index))
          }
        }.id('user-agreement-page').layoutWeight(1).height('100%').attributeModifier(PageStyles.reading)
          .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring).contentEndOffset(Space.xl)
          .onScrollIndex((first: number) => { this.selected = first; })
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    }.width('100%').height('100%')
      .onAreaChange((_old: Area, area: Area) => { this.panelWidth = Number(area.width); })
  }
}
