import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { ToolFailure } from '../model/ToolFailure';
import { Cancellation, RunCancelledError } from '../services/Cancellation';
import { linuxRuntime } from '../services/LinuxRuntime';
import { LinuxSerial, LinuxSerialEvents } from '../services/LinuxSerial';

type ConsolePhase = 'loading' | 'starting' | 'connected' | 'stopping' | 'stopped' | 'failed';
const TERMINAL_BACKGROUND: string = '#171B24';
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
  @State private running: boolean = false;
  @State private error: string = '';
  private mounted: boolean = false;
  private pageReady: boolean = false;
  private autoStart: boolean = true;
  private controller: webview.WebviewController = new webview.WebviewController();
  private serial?: LinuxSerial;
  private signal?: Cancellation;
  private columns: number = 80;
  private rows: number = 24;
  private startupTimer: number = -1;
  private output: Uint8Array[] = [];
  private outputBytes: number = 0;
  private receipt: number = 0;
  private inFlight: number = 0;
  private bridge: ConsoleBridge = new ConsoleBridge((text) => this.onInput(text), (columns, rows) => this.onSize(columns, rows),
    (receipt) => this.onWritten(receipt), (text) => this.copySelection(text));

  aboutToAppear(): void { this.mounted = true; }

  aboutToDisappear(): void {
    this.mounted = false;
    this.signal?.cancel();
    this.clearStartupTimer();
    this.discardOutput();
  }

  private visibilityChanged(): void {
    if (!this.active) { this.stop(); }
    else { this.startIfReady(); }
  }

  private async pageLoaded(): Promise<void> {
    if (!this.mounted || this.pageReady) { return; }
    try {
      await this.controller.runJavaScript('window.tinybotTerminal.configure(' + JSON.stringify(t('Linux 控制台')) + ',' +
        JSON.stringify(this.locale) + ')');
      if (!this.mounted) { return; }
      this.pageReady = true;
      this.startIfReady();
    } catch (error) { this.fail(error as Error); }
  }

  private startIfReady(): void {
    if (!this.mounted || !this.active || !this.pageReady || !this.autoStart) { return; }
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
    let connected = false;
    const events: LinuxSerialEvents = {
      ready: () => {
        if (!this.mounted || signal.cancelled) { return; }
        connected = true;
        this.clearStartupTimer();
        this.phase = 'connected';
        this.evaluate('window.tinybotTerminal.setConnected(true)');
        this.onSize(this.columns, this.rows);
      },
      output: (bytes) => this.queueOutput(bytes),
      failed: (error) => { if (!signal.cancelled) { this.fail(error); } }
    };
    const serial = new LinuxSerial(events);
    this.serial = serial;
    this.startupTimer = setTimeout(() => this.fail(new Error(t('Linux 控制台启动超时。'))), 45000);
    try {
      await this.controller.runJavaScript('window.tinybotTerminal.reset()');
      signal.check();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await linuxRuntime.runConsole(context, serial, signal);
      if (!connected && !signal.cancelled) { throw new Error(t('Linux 在控制台就绪前退出。')); }
    } catch (error) {
      if (!(error instanceof RunCancelledError)) { this.fail(error as Error); }
    } finally {
      this.clearStartupTimer();
      this.signal = undefined;
      this.serial = undefined;
      this.finish();
    }
  }

  private finish(): void {
    if (!this.mounted) { return; }
    this.running = false;
    if (this.phase !== 'failed') { this.phase = 'stopped'; }
    this.evaluate('window.tinybotTerminal.setConnected(false)');
  }

  private clearStartupTimer(): void {
    if (this.startupTimer >= 0) { clearTimeout(this.startupTimer); }
    this.startupTimer = -1;
  }

  private stop(): void {
    if (!this.signal || this.signal.cancelled) { return; }
    this.phase = 'stopping';
    this.signal.cancel();
  }

  private fail(error: Error): void {
    if (!this.mounted || this.phase === 'failed') { return; }
    this.clearStartupTimer();
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

  private onInput(text: string): void {
    if (this.phase === 'connected' && this.serial && typeof text === 'string' && text.length > 0) {
      this.serial.input(text).catch((error: Error) => this.fail(error));
    }
  }

  private onSize(columns: number, rows: number): void {
    if (!Number.isInteger(columns) || !Number.isInteger(rows) || columns < 2 || rows < 2) { return; }
    this.columns = Math.min(500, columns);
    this.rows = Math.min(300, rows);
    this.serial?.resize(this.columns, this.rows).catch((error: Error) => this.fail(error));
  }

  private discardOutput(): void {
    this.output = [];
    this.outputBytes = 0;
    this.inFlight = 0;
  }

  private queueOutput(bytes: Uint8Array): void {
    if (!this.mounted || this.signal?.cancelled) { return; }
    if (this.outputBytes + bytes.length > OUTPUT_LIMIT) {
      this.fail(new Error(t('终端输出过快，会话已停止。')));
      return;
    }
    this.output.push(bytes);
    this.outputBytes += bytes.length;
    this.flushOutput();
  }

  private flushOutput(): void {
    if (!this.mounted || !this.pageReady || this.inFlight !== 0 || this.outputBytes === 0) { return; }
    const batch = new Uint8Array(Math.min(this.outputBytes, BATCH_BYTES));
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
    this.evaluate('window.tinybotTerminal.write(' + JSON.stringify(encoded) + ',' + this.inFlight + ')');
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
    if (this.phase === 'connected') { return t('已连接'); }
    if (this.phase === 'starting') { return t('正在启动 Linux'); }
    if (this.phase === 'stopping') { return t('正在停止'); }
    if (this.phase === 'stopped') { return t('会话已结束'); }
    if (this.phase === 'failed') { return t('失败'); }
    return t('正在加载');
  }

  @Builder
  specialKey(name: string, label: string, accessibility: string) {
    Button(label).id('linux-console-key-' + name).fontFamily(this.appearance.fontFamily)
      .attributeModifier(Btn.tonal).constraintSize({ minWidth: 40, minHeight: 40 })
      .enabled(this.phase === 'connected').accessibilityText(accessibility)
      .onClick(() => this.evaluate('window.tinybotTerminal.key(' + JSON.stringify(name) + ')'))
  }

  @Builder
  controls() {
    Row({ space: Space.sm }) {
      Circle().width(8).height(8).fill(this.phase === 'connected' ? '#4C9C73' : $r('app.color.text_tertiary'))
        .accessibilityLevel('no')
      Text(this.status()).id('linux-console-status').fontFamily(this.appearance.fontFamily)
        .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (linuxRuntime.available) {
        Button(t('复制')).id('linux-console-copy').attributeModifier(Btn.textSmall).constraintSize({ minHeight: 44 })
          .enabled(this.phase === 'connected' || this.phase === 'stopped')
          .onClick(() => this.evaluate('window.tinybotTerminal.copy()'))
        PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
          .id('linux-console-paste').constraintSize({ minHeight: 44 })
          .enabled(this.phase === 'connected').onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (result === PasteButtonOnClickResult.SUCCESS) { this.paste(); }
            else { this.toast(t('无法访问剪贴板。')); }
          })
        if (this.phase === 'starting' || this.phase === 'connected' || this.phase === 'stopping') {
          Button(t('停止')).id('linux-console-stop').attributeModifier(Btn.textSmall).constraintSize({ minHeight: 44 })
            .enabled(this.phase !== 'stopping').onClick(() => this.stop())
        } else if (this.phase === 'stopped' || this.phase === 'failed') {
          Button(t('启动')).id('linux-console-start').attributeModifier(Btn.tonal).constraintSize({ minHeight: 44 })
            .enabled(this.pageReady && this.active && !this.running).onClick(() => this.start())
        }
      }
    }.width('100%').constraintSize({ minHeight: 48 })
  }

  build() {
    Column({ space: Space.sm }) {
      this.controls()
      if (this.error) { Banner({ text: this.error, compId: 'linux-console-error' }) }
      if (linuxRuntime.available) {
        Web({ src: TERMINAL_PAGE, controller: this.controller })
          .id('linux-console-web').width('100%').layoutWeight(1).borderRadius(Radius.md).clip(true)
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
        Scroll() {
          Row({ space: Space.xs }) {
            this.specialKey('esc', 'Esc', t('Escape 键'))
            this.specialKey('tab', 'Tab', t('Tab 键'))
            this.specialKey('interrupt', 'Ctrl+C', t('中断当前命令'))
            Blank().constraintSize({ minWidth: Space.sm })
            this.specialKey('left', '←', t('向左键'))
            this.specialKey('down', '↓', t('向下键'))
            this.specialKey('up', '↑', t('向上键'))
            this.specialKey('right', '→', t('向右键'))
          }.constraintSize({ minHeight: 44 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      } else {
        Column() {
          Text(t('当前安装包未包含 Linux 运行时。')).fontFamily(this.appearance.fontFamily)
            .fontSize(Font.body).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      }
    }.width('100%').height('100%').padding({ left: Space.md, right: Space.md, bottom: Space.sm })
      .backgroundColor($r('app.color.page_background'))
  }
}
