import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Motion, Radius, Space } from '../common/Theme';
import { Banner, IconButton } from '../common/Widgets';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { ToolFailure } from '../model/ToolFailure';
import { Cancellation, RunCancelledError } from '../services/Cancellation';
import { linuxRuntime } from '../services/LinuxRuntime';
import { LinuxSerialEvents } from '../services/LinuxSerial';

type ConsolePhase = 'loading' | 'starting' | 'connected' | 'stopping' | 'stopped' | 'failed';
const TERMINAL_BACKGROUND: string = '#1C1E20';
const TOOLBAR_INK: string = '#F2F0EA';
const FONT_SIZES: number[] = [12, 14, 16];
const CURSOR_STYLES: string[] = ['block', 'bar', 'underline'];

interface TerminalAppearance {
  fontSize: number;
  cursor: string;
}
const TERMINAL_PAGE: string = 'resource://rawfile/linux-console/index.html';
const OUTPUT_LIMIT: number = 1024 * 1024;
const BATCH_BYTES: number = 48 * 1024;

class ConsoleBridge {
  private input: (text: string) => void;
  private size: (columns: number, rows: number) => void;
  private written: (receipt: number) => void;
  private copy: (text: string) => void;
  constructor(input: (text: string) => void, size: (columns: number, rows: number) => void,
    written: (receipt: number) => void, copy: (text: string) => void) {
    this.input = input;
    this.size = size;
    this.written = written;
    this.copy = copy;
  }
  consoleInput(text: string): void { this.input(text); }
  consoleSize(columns: number, rows: number): void { this.size(columns, rows); }
  consoleWritten(receipt: number): void { this.written(receipt); }
  consoleCopy(text: string): void { this.copy(text); }
}

@Component
export struct LinuxConsolePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @Prop @Watch('visibilityChanged') active: boolean = false;
  @State private phase: ConsolePhase = 'loading';
  @State private terminalStyle: TerminalAppearance = { fontSize: 12, cursor: 'block' };
  onBack: () => void = () => {};
  onManage: () => void = () => {};
  @State private sandboxEnabled: boolean = linuxRuntime.snapshot().settings.enabled;
  @State private running: boolean = false;
  @State private terminalInUse: boolean = false;
  private unsubscribe?: () => void;
  @State private error: string = '';
  private mounted: boolean = false;
  private pageReady: boolean = false;
  private autoStart: boolean = true;
  private controller: webview.WebviewController = new webview.WebviewController();
  private signal?: Cancellation;
  private columns: number = 80;
  private rows: number = 24;
  private output: Uint8Array[] = [];
  private outputBytes: number = 0;
  private historyBytes: number = 0;
  private receipt: number = 0;
  private inFlight: number = 0;
  private bridge: ConsoleBridge = new ConsoleBridge((text) => this.onInput(text), (columns, rows) => this.onSize(columns, rows),
    (receipt) => this.onWritten(receipt), (text) => this.copySelection(text));

  private styleStore(): preferences.Preferences {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
  }

  aboutToAppear(): void {
    this.mounted = true;
    this.terminalInUse = linuxRuntime.snapshot().terminalInUse;
    this.unsubscribe = linuxRuntime.subscribe(() => {
      const busy = linuxRuntime.snapshot().terminalInUse;
      if (busy === this.terminalInUse) { return; }
      this.terminalInUse = busy;
      if (this.phase === 'connected') { this.updateInput(); }
    });
    try {
      const saved = this.styleStore().getSync('linuxConsoleAppearance', '');
      if (saved === '') { return; }
      const style = JSON.parse(saved as string) as TerminalAppearance;
      if (!style || !FONT_SIZES.includes(style.fontSize) || !CURSOR_STYLES.includes(style.cursor)) {
        throw new Error('Invalid Linux terminal appearance');
      }
      this.terminalStyle = style;
    } catch (error) { this.styleError(error as Error); }
  }

  private styleError(error: Error): void {
    Diagnostics.log('warn', 'linux-console', 'appearance_failed', {}, error);
    this.toast(t('终端外观') + ' · ' + error.message);
  }

  private applyTerminalStyle(): void {
    this.evaluate('window.tinybotTerminal.setAppearance(' + this.terminalStyle.fontSize + ',' +
      JSON.stringify(this.terminalStyle.cursor) + ')');
  }

  private chooseStyle(fontSize: number, cursor: string): void {
    const next: TerminalAppearance = { fontSize: fontSize, cursor: cursor };
    try {
      const store = this.styleStore();
      store.putSync('linuxConsoleAppearance', JSON.stringify(next));
      try { store.flushSync(); }
      catch (error) {
        store.putSync('linuxConsoleAppearance', JSON.stringify(this.terminalStyle));
        throw error as Error;
      }
      this.terminalStyle = next;
      this.applyTerminalStyle();
    } catch (error) { this.styleError(error as Error); }
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.unsubscribe?.();
    this.signal?.cancel();
    this.discardOutput();
  }

  private visibilityChanged(): void {
    if (!this.active) { this.autoStart = true; this.stop(); }
    else {
      this.sandboxEnabled = linuxRuntime.snapshot().settings.enabled;
      this.startIfReady();
    }
  }

  private async pageLoaded(): Promise<void> {
    if (!this.mounted || this.pageReady) { return; }
    try {
      await this.controller.runJavaScript('window.tinybotTerminal.configure(' + JSON.stringify(t('Linux 终端')) + ',' +
        JSON.stringify(this.locale) + ')');
      if (!this.mounted) { return; }
      this.pageReady = true;
      this.applyTerminalStyle();
      this.startIfReady();
    } catch (error) { this.fail(error as Error); }
  }

  private startIfReady(): void {
    if (!this.mounted || !this.active || !this.sandboxEnabled || !this.pageReady || !this.autoStart || this.signal) { return; }
    this.autoStart = false;
    this.start();
  }

  private async start(): Promise<void> {
    if (!this.mounted || !this.active || !this.pageReady || this.signal) { return; }
    this.error = '';
    this.discardOutput();
    this.phase = 'starting';
    this.running = true;
    const signal = new Cancellation();
    this.signal = signal;
    const events: LinuxSerialEvents = {
      ready: () => {
        if (!this.mounted || signal.cancelled) { return; }
        this.phase = 'connected';
        this.updateInput();
        this.onSize(this.columns, this.rows);
      },
      output: (bytes, history) => this.queueOutput(bytes, history),
      failed: (error) => { if (!signal.cancelled) { this.fail(error); } }
    };
    try {
      await this.controller.runJavaScript('window.tinybotTerminal.reset()');
      signal.check();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await linuxRuntime.runConsole(context, events, signal);
    } catch (error) {
      if (!(error instanceof RunCancelledError)) { this.fail(error as Error); }
    } finally {
      this.signal = undefined;
      this.finish();
      this.startIfReady();
    }
  }

  private finish(): void {
    if (!this.mounted) { return; }
    this.running = false;
    if (this.phase !== 'failed') { this.phase = 'stopped'; }
    this.evaluate('window.tinybotTerminal.setConnected(false)');
  }

  private stop(): void {
    if (!this.signal || this.signal.cancelled) { return; }
    this.phase = 'stopping';
    this.signal.cancel();
  }

  private fail(error: Error): void {
    if (!this.mounted || this.phase === 'failed') { return; }
    Diagnostics.log('warn', 'linux-console', 'session_failed', {}, error);
    this.error = error instanceof ToolFailure && error.code === 'BUSY' ? t('Linux 正在执行另一项任务。') : error.message;
    this.phase = 'failed';
    this.signal?.cancel();
    this.discardOutput();
  }

  private evaluate(script: string): void {
    if (this.mounted && this.pageReady) {
      this.controller.runJavaScript(script).catch((error: Error) => this.fail(error));
    }
  }

  private updateInput(): void {
    this.evaluate('window.tinybotTerminal.setConnected(' + String(!this.terminalInUse) + ')');
  }

  private onInput(text: string): void {
    if (this.terminalInUse) {
      if (text === '\x03') { linuxRuntime.stop(); }
      return;
    }
    if (this.phase === 'connected' && typeof text === 'string' && text.length > 0) {
      linuxRuntime.input(text).catch((error: Error) => this.fail(error));
    }
  }

  private onSize(columns: number, rows: number): void {
    if (!Number.isInteger(columns) || !Number.isInteger(rows) || columns < 2 || rows < 2) { return; }
    this.columns = Math.min(500, columns);
    this.rows = Math.min(300, rows);
    linuxRuntime.resize(this.columns, this.rows).catch((error: Error) => this.fail(error));
  }

  private discardOutput(): void {
    this.output = [];
    this.outputBytes = 0;
    this.historyBytes = 0;
    this.inFlight = 0;
  }

  private queueOutput(bytes: Uint8Array, history: boolean = false): void {
    if (!this.mounted || this.signal?.cancelled) { return; }
    if (this.outputBytes + bytes.length > OUTPUT_LIMIT) {
      this.fail(new Error(t('终端输出过快，请重新连接。')));
      return;
    }
    if (history) { this.historyBytes += bytes.length; }
    this.output.push(bytes);
    this.outputBytes += bytes.length;
    this.flushOutput();
  }

  private flushOutput(): void {
    if (!this.mounted || !this.pageReady || this.inFlight !== 0 || this.outputBytes === 0) { return; }
    const history = this.historyBytes > 0;
    const batch = new Uint8Array(Math.min(history ? this.historyBytes : this.outputBytes, BATCH_BYTES));
    if (history) { this.historyBytes -= batch.length; }
    let length = 0;
    while (length < batch.length) {
      const next = this.output[0];
      const count = Math.min(batch.length - length, next.length);
      batch.set(next.subarray(0, count), length);
      if (count === next.length) { this.output.shift(); }
      else { this.output[0] = next.subarray(count); }
      length += count;
    }
    this.outputBytes -= batch.length;
    this.inFlight = ++this.receipt;
    const encoded = new util.Base64Helper().encodeToStringSync(batch);
    this.evaluate('window.tinybotTerminal.write(' + JSON.stringify(encoded) + ',' + this.inFlight + ',' + String(history) + ')');
  }

  private onWritten(receipt: number): void {
    if (receipt === this.inFlight) {
      this.inFlight = 0;
      this.flushOutput();
    }
  }

  private toast(message: string): void {
    if (this.mounted) { this.getUIContext().getPromptAction().showToast({ message: message, systemMaterial: this.appearance.surface }); }
  }

  private async copySelection(text: string): Promise<void> {
    if (!this.mounted || typeof text !== 'string') { return; }
    if (!text) { this.toast(t('请先选中终端文本。')); return; }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.toast(t('已复制'));
    } catch (error) { this.clipboardError(error as Error); }
  }

  private async paste(): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const text = data.getPrimaryText();
      if (!text) { this.toast(t('剪贴板没有文本。')); return; }
      if (this.phase === 'connected') { this.evaluate('window.tinybotTerminal.paste(' + JSON.stringify(text) + ')'); }
    } catch (error) { this.clipboardError(error as Error); }
  }

  private clipboardError(error: Error): void {
    Diagnostics.log('warn', 'linux-console', 'clipboard_failed', {}, error);
    this.toast(t('无法访问剪贴板。'));
  }

  private status(): string {
    if (!linuxRuntime.available) { return t('不可用'); }
    if (!this.sandboxEnabled) { return t('已停用'); }
    if (this.phase === 'connected') { return this.terminalInUse ? t('助手正在执行命令') : t('终端已连接'); }
    if (this.phase === 'starting') { return t('正在启动 Linux'); }
    if (this.phase === 'stopping') { return t('正在断开'); }
    if (this.phase === 'stopped') { return t('终端已断开'); }
    if (this.phase === 'failed') { return t('失败'); }
    return t('正在加载');
  }

  @Builder
  specialKey(name: string, label: string, accessibility: string) {
    Button(label).id('linux-console-key-' + name).fontFamily(this.appearance.fontFamily)
      .type(ButtonType.Normal).width(name === 'interrupt' ? 56 : 44).height(44).padding(0)
      .fontSize(Font.caption + 1).fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .linearGradient({ angle: 180, colors: [[$r('app.color.console_key_top'), 0], [$r('app.color.console_key_bottom'), 1]] })
      .border({ width: { top: 0.5, left: 0.5, right: 0.5, bottom: 1 }, color: $r('app.color.console_key_edge'), radius: 9 })
      .shadow({ radius: 2, offsetY: 1, color: '#17000000' })
      .clickEffect(this.appearance.effectStrength > 0 ? Motion.pressSmall : null)
      .enabled(this.phase === 'connected' && (!this.terminalInUse || name === 'interrupt')).accessibilityText(accessibility)
      .onClick(() => {
        if (name === 'interrupt' && this.terminalInUse) { linuxRuntime.stop(); }
        else { this.evaluate('window.tinybotTerminal.key(' + JSON.stringify(name) + ')'); }
      })
  }

  private cursorLabel(style: string): string {
    if (style === 'bar') { return t('竖线'); }
    if (style === 'underline') { return t('下划线'); }
    return t('方块');
  }

  @Builder
  styleMenu() {
    Menu() {
      MenuItemGroup({ header: t('字号') }) {
        ForEach(FONT_SIZES, (size: number) => {
          MenuItem({ content: String(size) + ' px' }).id('linux-console-font-' + size)
            .selected(this.terminalStyle.fontSize === size).selectIcon(true)
            .onClick(() => this.chooseStyle(size, this.terminalStyle.cursor))
        }, (size: number) => String(size))
      }
      MenuItemGroup({ header: t('光标样式') }) {
        ForEach(CURSOR_STYLES, (style: string) => {
          MenuItem({ content: this.cursorLabel(style) }).id('linux-console-cursor-' + style)
            .selected(this.terminalStyle.cursor === style).selectIcon(true)
            .onClick(() => this.chooseStyle(this.terminalStyle.fontSize, style))
        }, (style: string) => style)
      }
    }
  }

  @Builder
  sessionButton(stop: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        if (stop) {
          Rect().width(9).height(9).radius(2).fill(this.appearance.onAccentContainer)
        } else {
          SymbolGlyph($r('sys.symbol.play_fill')).fontSize(12).fontColor([this.appearance.onAccentContainer])
        }
        Text(stop ? t('断开连接') : t('连接终端')).fontSize(Font.small).fontWeight(FontWeight.Medium)
          .fontColor(this.appearance.onAccentContainer).fontFamily(this.appearance.fontFamily)
      }
    }.id(stop ? 'linux-console-stop' : 'linux-console-start').height(44).padding({ left: 14, right: 14 })
      .backgroundColor(this.appearance.accentContainer).borderRadius(12)
      .accessibilityText(stop ? t('断开连接') : t('连接终端'))
      .enabled(stop ? this.phase !== 'stopping' : this.pageReady && this.active && !this.running)
      .onClick(() => { if (stop) { this.autoStart = false; this.stop(); } else { this.start(); } })
  }

  @Builder
  header() {
    Row({ space: Space.xs }) {
      IconButton({ chevron: 'left', label: t('返回'), compId: 'linux-console-back',
        fill: $r('app.color.console_canvas'), onTap: this.onBack })
      Text(t('Linux 终端')).fontSize(Font.title).fontWeight(FontWeight.Bold).fontFamily(this.appearance.fontFamily)
        .fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (linuxRuntime.available && this.sandboxEnabled) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.textformat')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }.id('linux-console-appearance').width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(t('终端外观')).bindMenu(this.styleMenu, { systemMaterial: this.appearance.menu, mask: false })
        if (this.phase === 'starting' || this.phase === 'connected' || this.phase === 'stopping') {
          this.sessionButton(true)
        } else {
          this.sessionButton(false)
        }
      }
    }.width('100%').constraintSize({ minHeight: 52 })
  }

  @Builder
  terminalBar() {
    Row({ space: Space.xs }) {
      Circle().width(8).height(8).fill(this.phase === 'connected' ? (this.terminalInUse ? '#E5BE72' : '#81D996') :
        this.phase === 'failed' ? '#F0A090' : '#A09F99').accessibilityLevel('no')
      Text(this.status()).id('linux-console-status').fontFamily(this.appearance.fontFamily).margin({ left: 3 })
        .fontSize(Font.small).fontColor(TOOLBAR_INK).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(19).fontColor([TOOLBAR_INK])
      }.id('linux-console-copy').width(44).height(44).padding(0).backgroundColor(TERMINAL_BACKGROUND)
        .enabled(this.phase === 'connected' || this.phase === 'stopped').accessibilityText(t('复制'))
        .onClick(() => this.evaluate('window.tinybotTerminal.copy()'))
      PasteButton({ icon: PasteIconStyle.LINES, buttonType: ButtonType.Normal })
        .id('linux-console-paste').width(44).height(44).iconSize(19).iconColor(TOOLBAR_INK)
        .backgroundColor(TERMINAL_BACKGROUND).borderRadius(8)
        .enabled(this.phase === 'connected' && !this.terminalInUse).onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
          if (result === PasteButtonOnClickResult.SUCCESS) { this.paste(); }
          else { this.toast(t('无法访问剪贴板。')); }
        })
    }.width('100%').padding({ left: 12, right: 4 })
  }

  build() {
    Column({ space: Space.sm }) {
      this.header()
      if (this.error) { Banner({ text: this.error, compId: 'linux-console-error' }) }
      if (linuxRuntime.available && this.sandboxEnabled) {
        Column() {
          this.terminalBar()
          Divider().strokeWidth(0.5).color('#464848').width('94%')
          Web({ src: TERMINAL_PAGE, controller: this.controller })
            .id('linux-console-web').width('100%').layoutWeight(1)
            .backgroundColor(TERMINAL_BACKGROUND).javaScriptAccess(true).domStorageAccess(false)
            .fileAccess(false).onlineImageAccess(false).blockNetwork(true).multiWindowAccess(false)
            .javaScriptProxy({ object: this.bridge, name: 'tinybotConsoleHost',
              methodList: ['consoleInput', 'consoleSize', 'consoleWritten', 'consoleCopy'], controller: this.controller })
            .onLoadIntercept((event) => event.data.isMainFrame() && (this.pageReady || event.data.getRequestUrl() !== TERMINAL_PAGE))
            .onPageEnd(() => this.pageLoaded())
            .onPermissionRequest((event) => event.request.deny())
            .onErrorReceive((event) => this.fail(new Error(event.error.getErrorInfo())))
            .onRenderExited(() => {
              this.pageReady = false;
              this.fail(new Error(t('终端界面已退出，请重新打开。')));
            })
        }.width('100%').layoutWeight(1).backgroundColor(TERMINAL_BACKGROUND).borderRadius(Radius.md).clip(true)
        Scroll() {
          Row({ space: Space.xs }) {
            this.specialKey('esc', 'Esc', t('Escape 键'))
            this.specialKey('tab', 'Tab', t('Tab 键'))
            this.specialKey('interrupt', 'Ctrl+C', t('中断当前命令'))
            this.specialKey('left', '←', t('向左键'))
            this.specialKey('down', '↓', t('向下键'))
            this.specialKey('up', '↑', t('向上键'))
            this.specialKey('right', '→', t('向右键'))
          }.padding({ top: 2, bottom: 3, left: 1, right: 1 }).constraintSize({ minHeight: 44 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      } else {
        Column({ space: Space.md }) {
          Text(this.status()).id('linux-console-status').fontSize(Font.small).fontColor($r('app.color.text_secondary'))
          Text(linuxRuntime.available ? t('启用 Linux 沙盒后即可使用控制台。') : t('当前安装包未包含 Linux 运行时。')).fontFamily(this.appearance.fontFamily)
            .fontSize(Font.body).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          if (linuxRuntime.available) {
            Button(t('沙盒管理')).id('linux-console-manage').attributeModifier(Btn.tonal).onClick(() => this.onManage())
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      }
    }.width('100%').height('100%').padding({ left: Space.md, right: Space.md, bottom: Space.sm })
      .backgroundColor($r('app.color.console_canvas'))
  }
}
