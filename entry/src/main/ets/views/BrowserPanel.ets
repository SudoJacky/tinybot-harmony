import { AppearanceStyle } from '../common/AppearanceStyle';
import { BrowserActionFeedback, BrowserSession } from '../services/BrowserSession';
import { NativeBrowserDriver, NativeBrowserCapture } from '../services/NativeBrowserDriver';
import { BrowserAnnotation, AnnotationPage } from '../model/BrowserAnnotation';
import { BrowserAnnotationBoard } from './BrowserAnnotationBoard';
import { image } from '@kit.ImageKit';
import { validateWebAddress } from '../services/WebTools';
import { Btn, Motion, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { t } from '../model/I18n';
import { KeyCode } from '@kit.InputKit';
import { Diagnostics } from '../model/Diagnostics';

// Always keep this host mounted. Expanding changes presentation, never the Web instance.
@Component
export struct BrowserPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink browser: BrowserSession;
  @Prop @Watch('syncBrowserVisibility') expanded: boolean = false;
  @Prop presented: boolean = false;
  @Prop threadId: string = '';
  @Prop canAnnotate: boolean = false;
  onAnnotation: (threadId: string, pixel: image.PixelMap, page: AnnotationPage, note: string) => Promise<void> = async () => {};
  onDismiss: () => void = () => {};
  onClose: () => void = () => {};
  onSettings: () => void = () => {};
  @State private address: string = '';
  @State private addressDirty: boolean = false;
  @State private capturing: boolean = false;
  @State private showAnnotation: boolean = false;
  @State private annotation: BrowserAnnotation = new BrowserAnnotation();
  @State private webWidth: number = 0;
  @State private webHeight: number = 0;
  private annotationCapture?: NativeBrowserCapture;
  private annotationThreadId: string = '';
  private mounted: boolean = false;
  private driver?: NativeBrowserDriver;
  aboutToAppear(): void { this.mounted = true; this.driver = new NativeBrowserDriver(this.browser); this.browser.attach(this.driver); this.syncBrowserVisibility(); }
  aboutToDisappear(): void { this.mounted = false; if (this.driver) { this.browser.detach(this.driver); } }
  private syncBrowserVisibility(): void { this.driver?.setFeedbackVisible(this.expanded); }
  private async annotate(): Promise<void> {
    if (!this.driver || this.capturing || this.showAnnotation || !this.canAnnotate) { return; }
    this.capturing = true; this.annotationThreadId = this.threadId;
    this.getUIContext().getFocusController().clearFocus();
    try {
      await this.browser.pauseForAnnotation();
      const capture = await this.driver.capture();
      if (!this.mounted) { await capture.pixel.release(); return; }
      this.annotationCapture = capture; this.annotation = new BrowserAnnotation(); this.showAnnotation = true;
      Diagnostics.log('info', 'browser', 'annotation_captured', { width: capture.width, height: capture.height });
    } catch (error) { this.browser.report((error as Error).message); }
    finally { this.capturing = false; }
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
      BrowserAnnotationBoard({ pixel: this.annotationCapture.pixel, pageTitle: this.annotationCapture.title || this.annotationCapture.url,
        captureWidth: this.annotationCapture.width, captureHeight: this.annotationCapture.height,
        draft: this.annotation, onClose: () => this.closeAnnotation(),
        onAdd: async (pixel: image.PixelMap, note: string) => {
          const capture = this.annotationCapture;
          if (!capture) { throw new Error(t('批注截图已失效，请重新截取。')); }
          await this.onAnnotation(this.annotationThreadId, pixel, capture, note);
          this.showAnnotation = false;
        } })
    }
  }
  private navigate(): void {
    try {
      this.driver?.userNavigate(validateWebAddress((this.browser.editingAddress || this.addressDirty ? this.address : this.browser.url).trim()));
      this.getUIContext().getFocusController().clearFocus();
    }
    catch (error) { this.browser.report((error as Error).message); }
  }
  build() {
    Column({ space: Space.sm }) {
      if ((this.browser.open || this.presented) && this.driver) {
        Row({ space: Space.sm }) {
          IconButton({ icon: $r('sys.symbol.chevron_down'), label: t('收起浏览器'), compId: 'browser-collapse', onTap: this.onDismiss })
          Column({ space: 2 }) {
            Text(this.browser.title || t('应用内浏览器')).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
            Text(this.browser.owner === 'agent' ? t('Tinybot 正在使用浏览器') : this.browser.hasTask ? t('浏览器由你控制 · 任务已暂停') : t('浏览器由你控制')).fontFamily(this.appearance.fontFamily)
              .fontSize(12).fontColor($r('app.color.text_secondary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          IconButton({ icon: $r('sys.symbol.gearshape'), label: t('设置'), compId: 'browser-settings', onTap: this.onSettings })
          IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭浏览器'), compId: 'browser-close',
            onTap: this.onClose })
        }.width('100%').height(56).padding({ left: Space.sm, right: Space.sm }).enabled(!this.capturing)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        Row({ space: Space.sm }) {
          TextInput({ text: this.browser.editingAddress || this.addressDirty ? this.address : this.browser.url, placeholder: t('网页地址') }).fontFamily(this.appearance.fontFamily)
            .id('browser-address').layoutWeight(1).type(InputType.URL).enterKeyType(EnterKeyType.Go)
            .onFocus(() => { if (!this.addressDirty) { this.address = this.browser.url; } this.browser.editingAddress = true; })
            .onBlur(() => { this.browser.editingAddress = false; })
            .onChange((value: string) => {
              if (this.browser.editingAddress && value !== this.address) { this.browser.takeOver(); this.addressDirty = true; }
              this.address = value;
            })
            .onSubmit(() => this.navigate())
          Button(t('打开')).fontFamily(this.appearance.fontFamily).id('browser-go').attributeModifier(Btn.textSmall).onClick(() => this.navigate())
        }.padding({ left: Space.md, right: Space.md }).width('100%').enabled(!this.capturing)
        Row({ space: Space.sm }) {
          IconButton({ icon: $r('sys.symbol.chevron_left'), label: t('上一页'), compId: 'browser-back',
            disabled: !this.browser.canGoBack, onTap: () => this.driver?.userBack() })
          IconButton({ icon: $r('sys.symbol.chevron_right'), label: t('下一页'), compId: 'browser-forward',
            disabled: !this.browser.canGoForward, onTap: () => this.driver?.userForward() })
          IconButton({ icon: $r('sys.symbol.arrow_clockwise'), label: t('重新加载'), compId: 'browser-reload', onTap: () => this.driver?.userReload() })
          Blank()
          IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: this.capturing ? t('截图中…') : t('批注当前页面'), compId: 'browser-annotate',
            disabled: !this.canAnnotate || this.capturing || this.browser.url.length === 0, onTap: () => this.annotate() })
          if (this.browser.owner === 'agent') {
            Button(t('接管浏览器')).fontFamily(this.appearance.fontFamily).id('browser-takeover').attributeModifier(Btn.tonal).onClick(() => this.browser.takeOver())
          }
          if (this.browser.owner === 'user' && this.browser.hasTask) {
            Button(t('交还给 Tinybot')).fontFamily(this.appearance.fontFamily).id('browser-handoff').attributeModifier(Btn.primarySmall)
              .onClick(() => { this.getUIContext().getFocusController().clearFocus(); this.browser.handoff(); })
          }
        }.width('100%').padding({ left: Space.sm, right: Space.md }).enabled(!this.capturing)
        if (this.browser.handoffReason) {
          Text(this.browser.handoffReason).fontFamily(this.appearance.fontFamily).id('browser-handoff-reason').fontSize(13).fontColor($r('app.color.text_secondary'))
            .width('100%').padding({ left: Space.md, right: Space.md })
        }
        if (this.browser.error) {
          Text(this.browser.error).fontFamily(this.appearance.fontFamily).id('browser-error').fontSize(13).fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice)
            .width('100%').padding({ left: Space.md, right: Space.md })
        }
        Stack({ alignContent: Alignment.TopStart }) {
        Web({ src: 'about:blank', controller: this.driver.controller })
          .enabled(!this.capturing)
          .id('agent-browser-web').width('100%').height('100%').javaScriptAccess(true).domStorageAccess(true)
          .fileAccess(false).multiWindowAccess(false).blockNetwork(false)
          .onPageBegin(() => this.driver?.pageBegin())
          .onPageEnd((event) => { this.driver?.pageEnd(event.url); if (!this.browser.editingAddress) { this.addressDirty = false; } })
          .onNavigationEntryCommitted(() => this.driver?.historyChanged())
          .onLoadIntercept((event) => {
            const url = event.data.getRequestUrl();
            if (url === 'about:blank') { return false; }
            try { validateWebAddress(url); return false; }
            catch (_) { this.driver?.failed(t('此浏览器仅支持 HTTP 和 HTTPS 网页。')); return true; }
          })
          .onErrorReceive((event) => { if (event.request.isMainFrame()) { this.driver?.failed(t('浏览器加载失败（{0}）。', [event.error.getErrorCode()])); } })
          .onHttpErrorReceive((event) => { if (event.request.isMainFrame()) { this.browser.report(t('浏览器返回 HTTP {0}。', [event.response.getResponseCode()])); } })
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
          .onAreaChange((_old: Area, next: Area) => { this.webWidth = Number(next.width); this.webHeight = Number(next.height); })
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
            SymbolGlyph($r('sys.symbol.connection')).fontSize(18).fontColor([this.appearance.accent])
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
