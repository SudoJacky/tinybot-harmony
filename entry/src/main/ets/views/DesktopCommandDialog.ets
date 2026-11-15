import { KeyCode } from '@kit.InputKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Font, Radius, Space } from '../common/Theme';
import { DesktopCommandItem, desktopCommandResults } from '../model/DesktopCommandPalette';
import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@CustomDialog
export struct DesktopCommandDialog {
  controller?: CustomDialogController;
  @ObjectLink app: ChatViewModel;
  commands: DesktopCommandItem[] = [];
  onChoose: (item: DesktopCommandItem) => void = () => {};
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @State private query: string = '';
  @State private results: DesktopCommandItem[] = [];
  @State private selected: number = 0;
  private scroller: Scroller = new Scroller();
  private accepted: boolean = false;
  private composing: boolean = false;

  aboutToAppear(): void { this.updateQuery(''); }

  private updateQuery(query: string): void {
    this.query = query;
    this.selected = 0;
    const needle = query.trim();
    const threads = needle.startsWith('>') || !this.app.canNavigate ? [] : this.app.filteredThreads(needle, false);
    this.results = desktopCommandResults(this.commands, query, threads, this.app.projects, t('普通聊天'));
    this.scroller.scrollEdge(Edge.Top);
  }

  private choose(item?: DesktopCommandItem): void {
    if (this.accepted || !item) { return; }
    this.accepted = true;
    this.onChoose(item);
    this.controller?.close();
  }

  private handleKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || this.composing) { return false; }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      event.stopPropagation();
      this.controller?.close();
      return true;
    }
    if (event.keyCode !== KeyCode.KEYCODE_DPAD_UP && event.keyCode !== KeyCode.KEYCODE_DPAD_DOWN) { return false; }
    if (this.results.length === 0 || event.getModifierKeyState?.(['Shift'])) { return false; }
    this.selected = Math.max(0, Math.min(this.results.length - 1,
      this.selected + (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN ? 1 : -1)));
    this.scroller.scrollToIndex(this.selected, false, ScrollAlign.AUTO);
    event.stopPropagation();
    return true;
  }

  @Builder
  result(item: DesktopCommandItem, index: number) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: Space.sm }) {
        SymbolGlyph(item.action === 'thread' ? $r('sys.symbol.ellipsis_message') : $r('sys.symbol.bolt'))
          .fontSize(16).width(24).fontColor([$r('app.color.text_secondary')]).accessibilityLevel('no')
        Column({ space: 3 }) {
          Text(item.label).fontFamily(this.appearance.fontFamily).fontSize(Font.small).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          if (item.excerpt) {
            Text(item.excerpt).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (item.detail) {
          Text(item.detail).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1)
            .constraintSize({ maxWidth: '38%' }).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_secondary'))
        }
      }.width('100%')
    }.id('desktop-command-' + item.action + '-' + item.id).width('100%').height(item.excerpt ? 52 : 40)
      .padding({ left: 8, right: 12 }).borderRadius(Radius.sm)
      .backgroundColor(this.selected === index ? $r('app.color.selection') : Color.Transparent)
      .accessibilitySelected(this.selected === index).focusOnTouch(false)
      .onHover((hover: boolean) => { if (hover) { this.selected = index; } })
      .onClick(() => this.choose(item))
  }

  build() {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        TextInput({ text: this.query, placeholder: t('搜索对话或命令') }).id('desktop-command-input')
          .layoutWeight(1).height(42).padding(0).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
          .backgroundColor(Color.Transparent).fontColor($r('app.color.text_primary')).defaultFocus(true)
          .enterKeyType(EnterKeyType.Go).accessibilityText(t('搜索对话或命令'))
          .onKeyPreIme((event: KeyEvent) => this.handleKey(event))
          .onChange((value: string, preview?: PreviewText) => {
            this.composing = !!preview?.value;
            if (!this.composing) { this.updateQuery(value); }
          })
          .onBlur(() => { this.composing = false; })
          .onSubmit(() => { if (!this.composing) { this.choose(this.results[this.selected]); } })
        Button('Esc').id('desktop-command-close').fontSize(Font.caption).height(28).padding({ left: 8, right: 8 })
          .borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant')).fontColor($r('app.color.text_secondary'))
          .accessibilityText(t('关闭')).onClick(() => this.controller?.close())
      }.width('100%').padding({ left: 10, right: 6 }).borderRadius(Radius.sm).backgroundColor($r('app.color.surface'))
      if (this.results.length === 0) {
        Text(t('没有匹配项')).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
          .fontColor($r('app.color.text_secondary')).layoutWeight(1).width('100%').textAlign(TextAlign.Center)
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.results, (item: DesktopCommandItem, index: number) => {
            ListItem() { this.result(item, index) }
          }, (item: DesktopCommandItem, index: number) => item.action + ':' + item.id + ':' + item.messageId + ':' + item.query + ':' + index)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      }
      Text(t('↑↓ 选择 · Enter 打开 · 输入 > 只看命令')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
        .fontColor($r('app.color.text_secondary')).width('100%').padding({ left: 8, right: 8 })
    }.id('desktop-command-dialog').width('100%').height(482).constraintSize({ maxHeight: '82%' })
      .padding(12).onKeyEvent((event: KeyEvent) => { this.handleKey(event); })
  }
}
