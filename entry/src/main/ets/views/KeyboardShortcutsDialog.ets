import { AppearanceStyle } from '../common/AppearanceStyle';
import { ShortcutGroup, ShortcutHint, shortcutGroups } from '../common/KeyboardShortcuts';
import { Font, Radius, Space } from '../common/Theme';
import { t } from '../model/I18n';

@CustomDialog
export struct KeyboardShortcutsDialog {
  controller?: CustomDialogController;
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @State private query: string = '';
  @State private groups: ShortcutGroup[] = shortcutGroups('');
  private scroller: Scroller = new Scroller();

  private updateQuery(value: string): void {
    this.query = value;
    this.groups = shortcutGroups(value);
    this.scroller.scrollEdge(Edge.Top);
  }

  @Builder
  shortcutRow(shortcut: ShortcutHint) {
    Row({ space: Space.md }) {
      Text(shortcut.label).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
        .fontColor($r('app.color.text_secondary')).layoutWeight(1)
      Text(shortcut.chord).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
        .fontColor($r('app.color.text_secondary')).maxLines(1)
        .padding({ left: 7, right: 7, top: 2, bottom: 2 }).borderRadius(Radius.sm)
        .backgroundColor($r('app.color.surface_variant'))
    }.id('keyboard-shortcut-' + shortcut.chord).width('100%').constraintSize({ minHeight: 36 })
      .padding({ top: Space.xs, bottom: Space.xs }).accessibilityGroup(true)
  }

  build() {
    Column({ space: Space.sm }) {
      Row() {
        Text(t('键盘快捷键')).fontFamily(this.appearance.fontFamily).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([$r('app.color.text_secondary')])
        }.id('keyboard-shortcuts-close').width(40).height(40).backgroundColor(Color.Transparent)
          .accessibilityText(t('关闭')).onClick(() => this.controller?.close())
      }.width('100%')
      Search({ value: this.query, placeholder: t('搜索快捷键') }).id('keyboard-shortcuts-search')
        .width('100%').height(36).borderRadius(18).border({ width: 1, color: $r('app.color.divider') })
        .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
        .textFont({ size: Font.small, family: this.appearance.fontFamily })
        .placeholderFont({ size: Font.small, family: this.appearance.fontFamily })
        .placeholderColor($r('app.color.text_tertiary')).enableKeyboardOnFocus(false).defaultFocus(true)
        .onChange((value: string) => this.updateQuery(value))
      Scroll(this.scroller) {
        Column() {
          if (this.groups.length === 0) {
            Text(t('没有匹配项')).id('keyboard-shortcuts-empty').fontFamily(this.appearance.fontFamily)
              .fontSize(Font.small).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
              .width('100%').padding({ top: Space.xl, bottom: Space.xl })
          }
          ForEach(this.groups, (group: ShortcutGroup) => {
            Text(group.label).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).width('100%').padding({ top: Space.md, bottom: Space.sm })
            ForEach(group.shortcuts, (shortcut: ShortcutHint) => {
              this.shortcutRow(shortcut)
            }, (shortcut: ShortcutHint) => shortcut.chord)
          }, (group: ShortcutGroup) => group.category + ':' + group.shortcuts.map((item) => item.chord).join(','))
        }.width('100%').padding({ right: Space.lg })
      }.id('keyboard-shortcuts-list').width('100%').layoutWeight(1).align(Alignment.TopStart)
        .scrollBar(BarState.Auto).scrollBarWidth(5).scrollBarColor($r('app.color.divider')).edgeEffect(EdgeEffect.None)
    }.id('keyboard-shortcuts-dialog').width('100%').height(560).constraintSize({ maxHeight: '84%' })
      .padding({ left: 20, right: 20, top: Space.md, bottom: Space.md })
  }
}
