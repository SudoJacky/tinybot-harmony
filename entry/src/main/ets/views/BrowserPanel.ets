import { AppearanceStyle } from '../common/AppearanceStyle';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { BrowserActionFeedback, BrowserSession } from '../services/BrowserSession';
import { NativeBrowserDriver, NativeBrowserCapture } from '../services/NativeBrowserDriver';
import { BrowserAnnotation, AnnotationPage } from '../model/BrowserAnnotation';
import { BrowserElementSelection, BrowserInspectorCommand } from '../model/BrowserScripts';
import { BrowserAnnotationBoard } from './BrowserAnnotationBoard';
import { BrowserElementEditor } from './BrowserElementEditor';
import { captureBrowserDraft } from '../services/BrowserAnnotationImage';
import { image } from '@kit.ImageKit';
import { validateWebAddress } from '../services/WebTools';
import { browserAddress, BrowserStartPreview } from '../model/BrowserAddress';
import { Btn, Font, Motion, Radius, Space } from '../common/Theme';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { IconButton } from '../common/Widgets';
import { t } from '../model/I18n';
import { KeyCode } from '@kit.InputKit';
import { Diagnostics } from '../model/Diagnostics';
import { WebUiView } from './WebUiView';
import { UiValues } from '../model/InteractiveUi';
import { Attachments } from '../services/Attachments';
import { PreviewBrowserRuntime } from '../services/PreviewBrowserRuntime';
import { BrowserRecents, BrowserVisit } from '../services/BrowserRecents';

@Component
struct BrowserPreviewPage {
  content: string = '';
  runtime?: PreviewBrowserRuntime;
  @Prop interactive: boolean = false;
  @State private values: UiValues = {};
  build() {
    WebUiView({ content: this.content, browserRuntime: this.runtime, values: this.values, interactive: this.interactive,
      onSave: async (values: UiValues): Promise<UiValues> => { this.values = values; return values; } })
  }
}

// Always keep this host mounted. Expanding changes presentation, never the Web instance.
@Component
export struct BrowserPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink @Watch('syncBrowserState') browser: BrowserSession;
  @StorageProp('tinybot.foreground') @Watch('syncBrowserVisibility') private foreground: boolean = true;
  @Prop @Watch('syncBrowserVisibility') expanded: boolean = false;
  @Prop presented: boolean = false;
  @Prop threadId: string = '';
  @Prop canAnnotate: boolean = false;
  // The docked tab strip owns the title and window controls.
  @Prop tabbed: boolean = false;
  @Prop startPreviews: BrowserStartPreview[] = [];
  onAnnotation: (threadId: string, pixel: image.PixelMap, page: AnnotationPage, note: string) => Promise<void> = async () => {};
  onScreenshot: (threadId: string, pixel: image.PixelMap) => Promise<void> = async () => {};
  onOpenPreview: (messageId: string, previewId: string) => void = () => {};
  onDismiss: () => void = () => {};
  onClose: () => void = () => {};
  onSettings: () => void = () => {};
  onPresent: () => void = () => {};
  @State private address: string = '';
  @State private addressDirty: boolean = false;
  @State private capturing: boolean = false;
  @State private showAnnotation: boolean = false;
  @State private pickingElement: boolean = false;
  @State private elementSelection: BrowserElementSelection | undefined = undefined;
  @State private inspectorWorking: boolean = false;
  @State private editorAtTop: boolean = false;
  @State private editorSpace: number = 0.58;
  @State private showElementProperties: boolean = true;
  @State private recent: BrowserVisit[] = [];
  @State private annotation: BrowserAnnotation = new BrowserAnnotation();
  @State private webWidth: number = 0;
  @State private webHeight: number = 0;
  private annotationCapture?: NativeBrowserCapture;
  private annotationThreadId: string = '';
  private selectionTimer: number = -1;
  private selectionDocument: number = -1;
  private selectionPreview: number = -1;
  private mounted: boolean = false;
  private driver?: NativeBrowserDriver;
  private recents?: BrowserRecents;
  aboutToAppear(): void {
    this.mounted = true;
    this.driver = new NativeBrowserDriver(this.browser, (pixel) => Attachments.savePreview(pixel), () => Math.min(this.webWidth, this.browser.preview?.viewportWidth || this.webWidth));
    this.browser.attach(this.driver, this.onPresent); this.syncBrowserVisibility();
    try {
      this.recents = new BrowserRecents(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.recent = this.recents.read();
    } catch (error) { Diagnostics.log('error', 'browser', 'history_read_failed', undefined, error as Error); }
  }
  aboutToDisappear(): void {
    this.mounted = false; this.dropElementSelection();
    if (this.driver) { this.browser.detach(this.driver); }
  }
  private syncBrowserState(): void {
    if (!this.browser.open && this.addressDirty) { this.addressDirty = false; this.address = ''; }
    if (this.elementSelection && (!this.browser.open || this.browser.owner !== 'user' || !this.sameSelectionDocument())) {
      this.dropElementSelection();
    }
  }
  private syncBrowserVisibility(): void {
    if (!this.expanded || !this.foreground) { this.pickingElement = false; }
    this.driver?.setFeedbackVisible(this.expanded); this.browser.setPresentation(this.expanded, this.foreground);
    this.scheduleElementRefresh();
  }
  private async annotate(screenshotOnly: boolean = false, selectionId?: number, note: string = '', stage: boolean = false): Promise<boolean> {
    const driver = this.driver;
    if (!driver || this.capturing || this.inspectorWorking || this.showAnnotation || !this.canAnnotate) { return false; }
    this.capturing = true;
    const threadId = this.threadId;
    this.annotationThreadId = threadId;
    // Keep the selected Web viewport stable until the screenshot and its bounds have both been read.
    if (selectionId === undefined) { this.getUIContext().getFocusController().clearFocus(); }
    try {
      return await captureBrowserDraft(async () => {
        await this.browser.pauseForAnnotation();
        return selectionId === undefined ? driver.capture() : driver.captureElement(selectionId);
      }, () => this.mounted && this.threadId === threadId && this.expanded && this.foreground,
      screenshotOnly ? 'screenshot' : stage ? 'note' : 'editor', note,
      (pixel, page, text) => page ? this.onAnnotation(threadId, pixel, page, text) : this.onScreenshot(threadId, pixel),
      (capture, draft) => {
        this.annotation = draft; this.annotationCapture = capture; this.showAnnotation = true;
        Diagnostics.log('info', 'browser', 'annotation_captured', { width: capture.width, height: capture.height });
      });
    } catch (error) { this.browser.report(error as Error); return false; }
    finally { this.capturing = false; }
  }
  private startElementPicking(): void {
    this.getUIContext().getFocusController().clearFocus();
    this.browser.takeOver(); this.pickingElement = true;
    this.scheduleElementRefresh();
  }
  private cancelElementPicking(): void {
    this.pickingElement = false;
    this.scheduleElementRefresh();
  }
  private sameSelectionDocument(): boolean {
    return this.selectionDocument === this.browser.documentVersion && this.selectionPreview === this.browser.previewInstance;
  }
  private dropElementSelection(): void {
    clearTimeout(this.selectionTimer); this.selectionTimer = -1;
    this.elementSelection = undefined; this.pickingElement = false;
  }
  private async pickAt(event: ClickEvent): Promise<void> {
    const driver = this.driver;
    if (!driver || !this.pickingElement || this.inspectorWorking || this.webWidth <= 0 || this.webHeight <= 0) { return; }
    const width = Math.min(this.webWidth, this.browser.preview?.viewportWidth || this.webWidth);
    const x = event.x / width, y = event.y / this.webHeight;
    this.inspectorWorking = true;
    try {
      await this.browser.pauseForAnnotation();
      if (!this.pickingElement || !this.mounted) { return; }
      const selection = await driver.inspectElement({ action: 'select', x: x, y: y });
      if (!selection || !this.mounted) { return; }
      this.selectionDocument = this.browser.documentVersion; this.selectionPreview = this.browser.previewInstance;
      const above = selection.mark?.y ?? y;
      const below = selection.mark ? 1 - selection.mark.y - selection.mark.height : 1 - y;
      this.elementSelection = selection; this.editorAtTop = above > below;
      this.editorSpace = Math.max(above, below); this.showElementProperties = true;
      this.pickingElement = false; this.browser.error = '';
    } catch (error) { this.browser.report(error as Error); }
    finally { this.inspectorWorking = false; this.scheduleElementRefresh(); }
  }
  private scheduleElementRefresh(): void {
    clearTimeout(this.selectionTimer); this.selectionTimer = -1;
    if (this.elementSelection && !this.pickingElement && this.expanded && this.foreground && this.mounted) {
      this.selectionTimer = setTimeout(() => this.refreshElementSelection(), 200);
    }
  }
  private async refreshElementSelection(): Promise<void> {
    const previous = this.elementSelection;
    const driver = this.driver;
    if (!previous || !driver || !this.expanded || !this.foreground || !this.mounted) { return; }
    if (!this.sameSelectionDocument()) { this.dropElementSelection(); return; }
    if (this.inspectorWorking || this.capturing) { this.scheduleElementRefresh(); return; }
    try {
      const current = await driver.inspectElement({ action: 'read', id: previous.id });
      if (this.elementSelection === previous && !this.pickingElement && !this.inspectorWorking && !this.capturing) {
        if (!current) {
          this.dropElementSelection(); this.browser.report(t('选中的元素已失效，请重新选择。'));
        } else if (current.viewport !== previous.viewport || JSON.stringify(current.mark) !== JSON.stringify(previous.mark)) {
          this.elementSelection = current;
        }
      }
      this.scheduleElementRefresh();
    } catch (error) {
      if (this.elementSelection === previous && this.sameSelectionDocument()) { this.browser.report(error as Error); }
    }
  }
  private async editElement(command: BrowserInspectorCommand): Promise<boolean> {
    const selected = this.elementSelection;
    if (!selected || !this.driver || this.capturing || this.inspectorWorking || !this.sameSelectionDocument()) { return false; }
    this.inspectorWorking = true;
    try {
      const selection = await this.driver.inspectElement({ action: command.action, id: selected.id, property: command.property, value: command.value });
      this.browser.error = '';
      if (selection) { this.elementSelection = selection; }
      else {
        this.dropElementSelection();
        if (command.action !== 'clear') { this.browser.report(t('选中的元素已失效，请重新选择。')); }
      }
      return true;
    } catch (error) { this.browser.report(error as Error); return false; }
    finally { this.inspectorWorking = false; this.scheduleElementRefresh(); }
  }
  private async handoffBrowser(): Promise<void> {
    this.getUIContext().getFocusController().clearFocus();
    if (this.elementSelection && !await this.editElement({ action: 'clear' })) { return; }
    this.pickingElement = false;
    this.browser.handoff();
  }
  private async captureElementNote(note: string, draw: boolean): Promise<void> {
    const selection = this.elementSelection;
    if (selection && await this.annotate(false, selection.id, note, !draw) && !draw && this.elementSelection?.id === selection.id) {
      await this.editElement({ action: 'clear' });
    }
  }
  private closeAnnotation(): void {
    if (this.annotation.saving) { return; }
    if (!this.annotation.dirty()) { this.showAnnotation = false; return; }
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('放弃这次批注？'),
      message: t('尚未添加到消息的批注将丢失。'), primaryButton: { value: t('继续批注'), action: () => {} },
      secondaryButton: { value: t('放弃'), action: () => { this.showAnnotation = false; } } });
  }
  @Builder
  annotationSheet() {
    if (this.annotationCapture) {
      BrowserAnnotationBoard({ pixel: this.annotationCapture.pixel, pageTitle: this.annotationCapture.element ?
        t('选中元素：{0}', [this.annotationCapture.element.label || this.annotationCapture.element.location]) :
        this.annotationCapture.title || this.annotationCapture.url,
        captureWidth: this.annotationCapture.width, captureHeight: this.annotationCapture.height,
        draft: this.annotation, onClose: () => this.closeAnnotation(),
        onAdd: async (pixel: image.PixelMap, note: string) => {
          const capture = this.annotationCapture;
          if (!capture) { throw new Error(t('批注截图已失效，请重新截取。')); }
          await this.onAnnotation(this.annotationThreadId, pixel, capture, note);
          this.showAnnotation = false;
          if (capture.element) { await this.editElement({ action: 'clear' }); }
        } })
    }
  }
  private navigate(): void {
    try {
      const url = browserAddress(this.addressDirty || this.browser.editingAddress ? this.address : this.browser.url);
      this.address = url; this.addressDirty = true;
      this.getUIContext().getFocusController().clearFocus();
      this.driver?.userNavigate(url);
    }
    catch (error) { this.browser.report(error as Error); }
  }
  private hasWebAddress(): boolean { return !this.browser.preview && /^https?:\/\//i.test(this.browser.url); }
  private canCapturePage(): boolean {
    return this.canAnnotate && !this.browser.loading && !this.browser.loadFailed && !!this.browser.url && !this.capturing && !this.inspectorWorking;
  }
  private loadRecent(visit: BrowserVisit): void {
    this.address = visit.url; this.addressDirty = true; this.navigate();
  }
  private rememberVisit(url: string): void {
    if (!this.recents || !this.browser.open || this.browser.owner !== 'user' || this.browser.loadFailed || !/^https?:\/\//i.test(url)) { return; }
    try { this.recent = this.recents.record(this.recent, url, this.browser.title); }
    catch (error) { this.browser.report(error as Error); }
  }
  private clearRecent(): void {
    try { this.recents?.write([]); this.recent = []; }
    catch (error) { this.browser.report(error as Error); }
  }

  private async useLink(external: boolean): Promise<void> {
    if (!this.hasWebAddress()) { return; }
    try {
      const url = validateWebAddress(this.browser.url);
      if (external) {
        await (this.getUIContext().getHostContext() as common.UIAbilityContext)
          .startAbility({ action: 'ohos.want.action.viewData', uri: url });
      } else {
        await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url));
        this.getUIContext().getPromptAction().showToast({ message: t('已复制链接') });
      }
    } catch (error) { this.browser.report(error as Error); }
  }

  @Builder
  recentMenu() {
    ForEach(this.recent, (visit: BrowserVisit) => {
      MenuItem({ content: visit.title || visit.url }).onClick(() => this.loadRecent(visit))
    }, (visit: BrowserVisit) => visit.url)
    MenuItem({ content: t('清除最近访问') }).id('browser-clear-recents').onClick(() => this.clearRecent())
  }

  @Builder
  browserMenu() {
    Menu() {
      MenuItem({ content: t('下一页') }).enabled(this.browser.canGoForward).onClick(() => this.driver?.userForward())
      MenuItem({ content: t('复制链接') }).enabled(this.hasWebAddress()).onClick(() => this.useLink(false))
      MenuItem({ content: t('在系统浏览器中打开') }).enabled(this.hasWebAddress()).onClick(() => this.useLink(true))
      MenuItem({ content: t('截图到消息'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.camera')) })
        .id('browser-screenshot').enabled(this.canCapturePage()).onClick(() => this.annotate(true))
      MenuItem({ content: t('选择网页元素'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.viewfinder_square')) })
        .id('browser-pick-element').enabled(this.canCapturePage()).onClick(() => this.startElementPicking())
      if (this.recent.length) { MenuItem({ content: t('最近访问'), builder: this.recentMenu }) }
      MenuItem({ content: t('设置') }).onClick(this.onSettings)
    }
  }

  @Builder
  moreButton(size: number) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(19).fontColor([$r('app.color.text_primary')])
    }.id('browser-more').width(size).height(size).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText(t('浏览器操作')).bindTips(t('浏览器操作'), { appearingTime: 550 })
      .bindMenu(this.browserMenu, { systemMaterial: this.appearance.menu, mask: false })
  }

  @Builder
  controlButton() {
    if (this.browser.owner === 'agent') {
      Button(t('接管')).fontFamily(this.appearance.fontFamily).id('browser-takeover')
        .accessibilityText(t('接管浏览器')).attributeModifier(Btn.tonalSmall).onClick(() => this.browser.takeOver())
    } else if (this.browser.hasTask) {
      Button(t('交还')).fontFamily(this.appearance.fontFamily).id('browser-handoff')
        .accessibilityText(t('交还给 Tinybot')).attributeModifier(Btn.primarySmall)
        .onClick(() => this.handoffBrowser())
    }
  }

  @Builder
  phoneHeader() {
    Row({ space: 4 }) {
      IconButton({ icon: $r('sys.symbol.chevron_down'), label: t('收起浏览器'), compId: 'browser-collapse',
        iconSize: 18, fill: '#00000000', onTap: this.onDismiss })
      Column({ space: 1 }) {
        Text(this.browser.url && this.browser.title ? this.browser.title : t('应用内浏览器'))
          .fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        if (this.browser.hasTask) {
          Text(this.browser.owner === 'agent' ? t('Tinybot 正在使用浏览器') : t('浏览器由你控制 · 任务已暂停'))
            .fontFamily(this.appearance.fontFamily).fontSize(11).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      this.controlButton()
      this.moreButton(44)
      IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭浏览器'), compId: 'browser-close',
        iconSize: 18, fill: '#00000000', onTap: this.onClose })
    }.width('100%').height(48).padding({ left: 4, right: 4 }).enabled(!this.capturing)
  }

  @Builder
  addressField() {
    Row() {
      TextInput({ text: this.browser.editingAddress || this.addressDirty ? this.address : this.hasWebAddress() ? this.browser.url : '',
        placeholder: t('搜索或输入网址') }).fontFamily(this.appearance.fontFamily)
        .id('browser-address').layoutWeight(1).height(36).fontSize(Font.small).backgroundColor(Color.Transparent)
        .padding({ left: 10, right: 4 }).enterKeyType(EnterKeyType.Go)
        .onFocus(() => {
          if (!this.addressDirty) { this.address = this.hasWebAddress() ? this.browser.url : ''; }
          this.browser.editingAddress = true;
        })
        .onBlur(() => { this.browser.editingAddress = false; })
        .onChange((value: string) => {
          if (this.browser.editingAddress && value !== this.address) { this.browser.takeOver(); this.addressDirty = true; }
          this.address = value;
        })
        .onSubmit(() => this.navigate())
      if (this.addressDirty && this.address.trim().length > 0) {
        IconButton({ icon: $r('sys.symbol.chevron_right'), label: t('打开'), compId: 'browser-go', diameter: 36,
          fill: '#00000000', tint: this.appearance.accent, iconSize: 15, onTap: () => this.navigate() })
      }
    }.layoutWeight(1).backgroundColor($r('app.color.surface_variant')).borderRadius(Radius.lg)
  }

  @Builder
  navigationToolbar() {
    Row({ space: 2 }) {
      IconButton({ icon: $r('sys.symbol.chevron_left'), label: t('上一页'), compId: 'browser-back',
        diameter: this.tabbed ? 36 : 44, iconSize: 18, fill: '#00000000', disabled: !this.browser.canGoBack,
        onTap: () => this.driver?.userBack() })
      if (this.tabbed && this.webWidth >= 360) {
        IconButton({ icon: $r('sys.symbol.chevron_right'), label: t('下一页'), compId: 'browser-forward',
          diameter: 36, iconSize: 18, fill: '#00000000', disabled: !this.browser.canGoForward,
          onTap: () => this.driver?.userForward() })
      }
      IconButton({ icon: this.browser.loading ? $r('sys.symbol.stop_circle') : $r('sys.symbol.arrow_clockwise'),
        label: this.browser.loading ? t('停止加载') : t('重新加载'), compId: 'browser-reload',
        diameter: this.tabbed ? 36 : 44, iconSize: 18, fill: '#00000000',
        disabled: !this.browser.loading && !this.browser.url && !this.browser.loadFailed,
        onTap: () => {
          if (this.browser.loading) { this.driver?.userStop(); } else { this.driver?.userReload(); }
        } })
      this.addressField()
      IconButton({ icon: this.pickingElement ? $r('sys.symbol.xmark') : $r('sys.symbol.viewfinder_square'),
        label: this.pickingElement ? t('取消选择') : t('选择网页元素'), compId: 'browser-annotate',
        diameter: this.tabbed ? 36 : 44, iconSize: 18, fill: '#00000000',
        disabled: !this.pickingElement && !this.canCapturePage(),
        onTap: () => { if (this.pickingElement) { this.cancelElementPicking(); } else { this.annotate(); } } })
      if (this.tabbed) { this.moreButton(36) }
    }.width('100%').height(this.tabbed ? 46 : 48).padding({ left: 4, right: 6 }).enabled(!this.capturing)
  }

  private elementEditorHeight(): number {
    const available = Math.min(this.webHeight * 0.58, this.webHeight * this.editorSpace - 2 * Space.lg);
    return this.showElementProperties ? Math.max(178, Math.min(386, available)) : 126;
  }

  @Builder
  elementEditor() {
    Stack() {
      BrowserElementEditor({ selection: this.elementSelection, capturing: this.capturing,
        showProperties: this.showElementProperties, captureEnabled: this.canCapturePage() && !!this.elementSelection?.mark,
        onToggleProperties: () => { this.showElementProperties = !this.showElementProperties; },
        onStyle: (property: string, value: string) => this.editElement({ action: 'style', property: property, value: value }),
        onReset: () => this.editElement({ action: 'reset' }),
        onCancel: () => { this.editElement({ action: 'clear' }); },
        onCapture: (note: string, draw: boolean) => this.captureElementNote(note, draw) })
    }.width(Math.min(372, this.webWidth - 2 * Space.sm)).height(this.elementEditorHeight())
      .position({ x: Math.max(Space.sm, this.webWidth - 372 - Space.sm),
        y: this.editorAtTop ? Space.sm : Math.max(Space.sm, this.webHeight - this.elementEditorHeight() - Space.lg) })
  }

  @Builder
  elementHighlight() {
    Stack() {}
      .id('browser-element-highlight')
      .width((this.elementSelection?.mark?.width || 0) * Math.min(this.webWidth, this.browser.preview?.viewportWidth || this.webWidth))
      .height((this.elementSelection?.mark?.height || 0) * this.webHeight).border({ width: 2, color: this.appearance.accent })
      .position({ x: (this.elementSelection?.mark?.x || 0) * Math.min(this.webWidth, this.browser.preview?.viewportWidth || this.webWidth),
        y: (this.elementSelection?.mark?.y || 0) * this.webHeight })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }

  @Builder
  startPage() {
    Scroll() {
      Column({ space: Space.md }) {
        SymbolGlyph($r('sys.symbol.worldclock')).fontSize(30).fontColor([this.appearance.accent])
          .backgroundColor(this.appearance.accentTint).borderRadius(Radius.lg).padding(14)
        Text(t('打开网页或预览')).fontFamily(this.appearance.fontFamily).fontSize(20)
          .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(t('搜索网页、输入网址，或打开本会话已发布的预览。'))
          .fontFamily(this.appearance.fontFamily).fontSize(Font.small).textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_secondary'))
        Button(t('输入网址')).id('browser-start-address').attributeModifier(Btn.tonal)
          .onClick(() => this.getUIContext().getFocusController().requestFocus('browser-address'))
        if (this.startPreviews.length) {
          Text(t('本会话的预览')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
            .fontColor($r('app.color.text_secondary')).width('100%').margin({ top: Space.lg })
          ForEach(this.startPreviews, (preview: BrowserStartPreview) => {
            Button(preview.title).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.tonal)
              .width('100%').id('browser-start-preview-' + preview.id)
              .onClick(() => this.onOpenPreview(preview.messageId, preview.id))
          }, (preview: BrowserStartPreview) => preview.id)
        }
        if (this.recent.length) {
          Row() {
            Text(t('最近访问')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
              .fontColor($r('app.color.text_secondary')).layoutWeight(1)
            Button(t('清除')).attributeModifier(Btn.textSmall).id('browser-start-clear-recents').onClick(() => this.clearRecent())
          }.width('100%').margin({ top: Space.md })
          ForEach(this.recent, (visit: BrowserVisit, index: number) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 2 }) {
                Text(visit.title || visit.url).fontSize(Font.small).fontColor($r('app.color.text_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(visit.url).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.id('browser-recent-' + index).width('100%').height(52).borderRadius(Radius.md)
              .padding({ left: Space.md, right: Space.md }).backgroundColor($r('app.color.surface_variant'))
              .onClick(() => this.loadRecent(visit))
          }, (visit: BrowserVisit) => visit.url)
        }
      }.width('100%').constraintSize({ maxWidth: 460 }).padding({ left: 20, right: 20, top: 52, bottom: 24 })
    }.id('browser-start').width('100%').height('100%').align(Alignment.Top).backgroundColor($r('app.color.surface'))
  }

  @Builder
  failurePage() {
    Column({ space: Space.md }) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(26).fontColor([this.appearance.accent])
      Text(t('网页加载失败')).fontFamily(this.appearance.fontFamily).fontSize(Font.title).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(this.browser.error).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
        .textAlign(TextAlign.Center).fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.LocalDevice)
      Button(t('重试')).id('browser-retry').attributeModifier(Btn.primary).onClick(() => this.driver?.userReload())
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(Space.xl)
      .backgroundColor($r('app.color.surface'))
  }
  build() {
    Column() {
      if ((this.browser.open || this.presented) && this.driver) {
        if (!this.tabbed) { this.phoneHeader() }
        this.navigationToolbar()
        if (this.tabbed && this.browser.hasTask) {
          Row({ space: Space.sm }) {
            Text(this.browser.owner === 'agent' ? t('Tinybot 正在使用浏览器') : t('浏览器由你控制 · 任务已暂停'))
              .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              .maxLines(2).layoutWeight(1)
            this.controlButton()
          }.width('100%').padding({ left: Space.md, right: Space.md, bottom: Space.xs }).enabled(!this.capturing)
        }
        if (this.browser.handoffReason) {
          Text(this.browser.handoffReason).fontFamily(this.appearance.fontFamily).id('browser-handoff-reason').fontSize(Font.caption)
            .fontColor($r('app.color.text_secondary')).width('100%').padding({ left: Space.md, right: Space.md, bottom: Space.sm })
        }
        if (this.browser.error && !this.browser.loadFailed) {
          Text(this.browser.error).fontFamily(this.appearance.fontFamily).id('browser-error').fontSize(Font.caption)
            .fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice)
            .width('100%').padding({ left: Space.md, right: Space.md, bottom: Space.sm })
        }
        if (this.browser.loading) {
          Progress({ value: this.browser.progress, total: 100, type: ProgressType.Linear }).id('browser-progress')
            .width('100%').color(this.appearance.accent).style({ strokeWidth: 2 }).accessibilityText(t('正在加载网页'))
        } else {
          Divider().strokeWidth(0.5).color($r('app.color.divider'))
        }
        Stack({ alignContent: Alignment.TopStart }) {
        if (this.browser.preview) {
          ForEach([this.browser.previewInstance], (_instance: number) => {
            BrowserPreviewPage({ content: this.browser.previewSpec, interactive: this.expanded && this.foreground,
              runtime: this.driver?.previewRuntime })
              .width(this.browser.preview?.viewportWidth || '100%').constraintSize({ maxWidth: '100%' })
              .onTouch((event: TouchEvent) => this.driver?.userTouch(event))
              .onMouse((event: MouseEvent) => { if (event.action === MouseAction.Press) { this.browser.takeOver(); } })
          }, (instance: number) => String(instance))
        } else {
        Web({ src: 'about:blank', controller: this.driver.controller })
          .enabled(!this.capturing)
          .id('agent-browser-web').width('100%').height('100%').javaScriptAccess(true).domStorageAccess(true)
          .fileAccess(false).multiWindowAccess(false).blockNetwork(false)
          .onPageBegin((event) => { this.dropElementSelection(); this.driver?.pageBegin(event.url); })
          .onProgressChange((event) => this.driver?.progress(event.newProgress))
          .onPageEnd((event) => {
            this.driver?.pageEnd(event.url);
            if (!this.browser.editingAddress && !this.browser.loadFailed && event.url !== 'about:blank') { this.addressDirty = false; }
            this.rememberVisit(event.url);
          })
          .onNavigationEntryCommitted(() => this.driver?.historyChanged())
          .onLoadIntercept((event) => {
            const url = event.data.getRequestUrl();
            if (url === 'about:blank') { return false; }
            try { validateWebAddress(url); return false; }
            catch (_) { this.browser.report(t('此浏览器仅支持 HTTP 和 HTTPS 网页。')); return true; }
          })
          .onErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.driver?.failed(t('浏览器加载失败（{0}）。', [event.error.getErrorCode()]), event.request.getRequestUrl());
            }
          })
          .onHttpErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.driver?.failed(t('浏览器返回 HTTP {0}。', [event.response.getResponseCode()]), event.request.getRequestUrl());
            }
          })
          .onRenderExited(() => { this.driver?.failed(t('浏览器渲染进程已退出，请关闭后重新打开。')); this.browser.close(); })
          .onPermissionRequest((event) => { event.request.deny(); this.browser.report(t('浏览器未授权摄像头、麦克风或位置访问。')); })
          .onTouch((event) => this.driver?.userTouch(event))
          .onMouse((event) => { if (event.action === MouseAction.Press) { this.browser.takeOver(); } })
          .onInterceptKeyEvent((event) => {
            // Arrow/Page/Home/End keys only move the viewport; editing and activation take control.
            if (event.type === KeyType.Down && ![KeyCode.KEYCODE_DPAD_UP, KeyCode.KEYCODE_DPAD_DOWN,
              KeyCode.KEYCODE_DPAD_LEFT, KeyCode.KEYCODE_DPAD_RIGHT, KeyCode.KEYCODE_PAGE_UP, KeyCode.KEYCODE_PAGE_DOWN,
              KeyCode.KEYCODE_MOVE_HOME, KeyCode.KEYCODE_MOVE_END, KeyCode.KEYCODE_CTRL_LEFT, KeyCode.KEYCODE_CTRL_RIGHT,
              KeyCode.KEYCODE_SHIFT_LEFT, KeyCode.KEYCODE_SHIFT_RIGHT].includes(event.keyCode)) { this.browser.takeOver(); }
            return false;
          })
        }
          if (this.browser.loadFailed) {
            this.failurePage()
          } else if (!this.browser.preview && !this.browser.url && !this.browser.loading) {
            this.startPage()
          }
          if (this.elementSelection?.mark && !this.pickingElement && this.expanded && this.foreground) {
            this.elementHighlight()
          }
          if (this.pickingElement) {
            Stack({ alignContent: Alignment.Bottom }) {
              Text(t('点按要检查的网页元素')).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
                .fontColor(this.appearance.onAccent).backgroundColor(this.appearance.accent)
                .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
                .borderRadius(Radius.xl).margin({ bottom: Space.lg }).hitTestBehavior(HitTestMode.None)
            }.id('browser-pick-surface').width(this.browser.preview?.viewportWidth || '100%').constraintSize({ maxWidth: '100%' })
              .height('100%').backgroundColor('#01000000').hitTestBehavior(HitTestMode.Block)
              .onClick((event: ClickEvent) => this.pickAt(event))
          }
          if (!this.pickingElement && this.elementSelection && this.expanded && this.foreground && this.webWidth > 100) {
            ForEach([this.elementSelection.id], (_id: number) => { this.elementEditor() }, (id: number) => String(id))
          }
          ForEach(this.expanded && this.browser.owner === 'agent' && this.browser.actionFeedback ? [this.browser.actionFeedback] : [],
            (feedback: BrowserActionFeedback) => {
              Stack() {
                Circle().width(32).height(32).fill(this.appearance.accentTint).stroke(this.appearance.accent).strokeWidth(2)
                Circle().width(6).height(6).fill(this.appearance.accent)
              }.id('browser-agent-action').width(32).height(32)
                .position({ x: feedback.x * this.webWidth - 16, y: feedback.y * this.webHeight - 16 })
                .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
                .transition(TransitionEffect.asymmetric(
                  TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })).animation({ duration: Motion.fast, curve: Motion.standard }),
                  TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 1.4, y: 1.4 })).animation({ duration: Motion.medium, curve: Motion.standard })))
            }, (feedback: BrowserActionFeedback) => String(feedback.id))
        }.width('100%').layoutWeight(1).clip(true)
          .onAreaChange((_old: Area, next: Area) => {
            if (this.webWidth !== Number(next.width) || this.webHeight !== Number(next.height)) { this.browser.invalidateObservation(); }
            this.webWidth = Number(next.width); this.webHeight = Number(next.height);
          })
      }
    }.id('agent-browser-panel').width('100%').height('100%').backgroundColor($r('app.color.surface'))
      // The shared AnimatedPage owns presentation; this Web host stays attached while hidden.
      .hitTestBehavior(this.expanded && this.browser.open ? HitTestMode.Default : HitTestMode.None)
      .enabled(this.expanded && this.browser.open)
      .accessibilityLevel(this.expanded && this.browser.open ? 'auto' : 'no-hide-descendants')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .bindContentCover(this.showAnnotation, this.annotationSheet(), { modalTransition: ModalTransition.ALPHA,
        onWillDismiss: () => this.closeAnnotation() })
  }
}

@Component
export struct BrowserStatusCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink browser: BrowserSession;
  onOpen: () => void = () => {};
  build() {
    Column({ space: Space.sm }) {
      if (this.browser.permissionPending) {
        Text(t('允许启用应用内浏览器？')).fontFamily(this.appearance.fontFamily).id('browser-permission-title').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(this.browser.permissionReason).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
        Text(this.browser.permissionUrl).fontFamily(this.appearance.fontFamily).fontSize(12).maxLines(2).fontColor($r('app.color.text_secondary'))
        Text(t('你可以随时接管浏览器，也可以在设置中关闭。网页内容会发送给当前模型。')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
        Row({ space: Space.sm }) {
          Button(t('保持关闭')).fontFamily(this.appearance.fontFamily).id('browser-permission-deny').attributeModifier(Btn.plainSmall).layoutWeight(1).enabled(!this.browser.permissionSaving)
            .onClick(async () => { try { await this.browser.setEnabled(false); } catch (_) { /* The browser exposes the save error. */ } })
          Button(t('允许并启用')).fontFamily(this.appearance.fontFamily).id('browser-permission-allow').attributeModifier(Btn.primarySmall).layoutWeight(1).enabled(!this.browser.permissionSaving)
            .onClick(async () => { try { await this.browser.setEnabled(true); } catch (_) { /* The browser exposes the save error. */ } })
        }.width('100%')
      } else if (this.browser.open) {
        Button() {
          Row({ space: Space.sm }) {
            SymbolGlyph($r('sys.symbol.worldclock')).fontSize(18).fontColor([this.appearance.accent])
            Column({ space: 2 }) {
              Text(this.browser.owner === 'agent' ? t('Tinybot 正在使用浏览器') : this.browser.hasTask ? t('浏览器由你控制 · 任务已暂停') : t('浏览器由你控制')).fontFamily(this.appearance.fontFamily)
                .fontSize(13).fontColor($r('app.color.text_primary'))
              Text(this.browser.handoffReason || this.browser.title || this.browser.url).fontFamily(this.appearance.fontFamily).fontSize(12).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          }.width('100%')
        }.fontFamily(this.appearance.fontFamily).id('open-agent-browser').attributeModifier(Btn.plainSmall).width('100%').onClick(this.onOpen)
      }
      if (this.browser.error) {
        Text(this.browser.error).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.danger')).width('100%')
      }
    }.width('100%').padding(Space.sm).backgroundColor($r('app.color.surface_variant')).borderRadius(12)
  }
}
