import { BrowserSession } from '../services/BrowserSession';
import { NativeBrowserDriver } from '../services/NativeBrowserDriver';
import { validateWebAddress } from '../services/WebTools';
import { Btn, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { t } from '../model/I18n';

// Always keep this host mounted. Expanding changes presentation, never the Web instance.
@Component
export struct BrowserPanel {
  @ObjectLink browser: BrowserSession;
  @Prop expanded: boolean = false;
  onDismiss: () => void = () => {};
  onSettings: () => void = () => {};
  @State private address: string = '';
  private driver?: NativeBrowserDriver;
  aboutToAppear(): void { this.driver = new NativeBrowserDriver(this.browser); this.browser.attach(this.driver); }
  aboutToDisappear(): void { if (this.driver) { this.browser.detach(this.driver); } }
  private navigate(): void {
    try { this.driver?.userNavigate(validateWebAddress(this.address.trim())); }
    catch (error) { this.browser.report((error as Error).message); }
  }
  build() {
    Column({ space: Space.sm }) {
      if (this.browser.open && this.driver) {
        Row({ space: Space.sm }) {
          IconButton({ icon: $r('sys.symbol.chevron_down'), label: t('收起浏览器'), compId: 'browser-collapse', onTap: this.onDismiss })
          Column({ space: 2 }) {
            Text(this.browser.title || t('应用内浏览器')).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
            Text(this.browser.owner === 'agent' ? t('Tinybot 正在使用浏览器') : this.browser.hasTask ? t('浏览器由你控制 · 任务已暂停') : t('浏览器由你控制'))
              .fontSize(12).fontColor($r('app.color.text_secondary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          IconButton({ icon: $r('sys.symbol.gearshape'), label: t('设置'), compId: 'browser-settings', onTap: this.onSettings })
          IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭浏览器'), compId: 'browser-close',
            onTap: () => { this.browser.close(); this.onDismiss(); } })
        }.width('100%').padding({ left: Space.sm, right: Space.sm, top: Space.sm })
        Row({ space: Space.sm }) {
          TextInput({ text: this.address || this.browser.url, placeholder: t('网页地址') }).id('browser-address').layoutWeight(1)
            .onTouchIntercept((event) => { if (event.type === TouchType.Down) { this.browser.takeOver(); } return HitTestMode.Default; })
            .onChange((value: string) => { this.address = value; })
            .onSubmit(() => this.navigate())
          Button(t('打开')).id('browser-go').attributeModifier(Btn.textSmall).onClick(() => this.navigate())
        }.padding({ left: Space.md, right: Space.md }).width('100%')
        Row({ space: Space.sm }) {
          IconButton({ icon: $r('sys.symbol.chevron_left'), label: t('上一页'), compId: 'browser-back', onTap: () => this.driver?.userBack() })
          IconButton({ icon: $r('sys.symbol.chevron_right'), label: t('下一页'), compId: 'browser-forward', onTap: () => this.driver?.userForward() })
          IconButton({ icon: $r('sys.symbol.arrow_clockwise'), label: t('重新加载'), compId: 'browser-reload', onTap: () => this.driver?.userReload() })
          Blank()
          if (this.browser.owner === 'user' && this.browser.hasTask) {
            Button(t('交还给 Tinybot')).id('browser-handoff').attributeModifier(Btn.primarySmall)
              .onClick(() => { this.getUIContext().getFocusController().clearFocus(); this.browser.handoff(); })
          }
        }.width('100%').padding({ left: Space.sm, right: Space.md })
        if (this.browser.handoffReason) {
          Text(this.browser.handoffReason).id('browser-handoff-reason').fontSize(13).fontColor($r('app.color.text_secondary'))
            .width('100%').padding({ left: Space.md, right: Space.md })
        }
        if (this.browser.error) {
          Text(this.browser.error).id('browser-error').fontSize(13).fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice)
            .width('100%').padding({ left: Space.md, right: Space.md })
        }
        Web({ src: 'about:blank', controller: this.driver.controller })
          .id('agent-browser-web').width('100%').layoutWeight(1).javaScriptAccess(true).domStorageAccess(true)
          .fileAccess(false).multiWindowAccess(false).blockNetwork(false)
          .onPageBegin(() => this.driver?.pageBegin())
          .onPageEnd((event) => { this.address = ''; this.driver?.pageEnd(event.url); })
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
          .onTouchIntercept((event) => { if (event.type === TouchType.Down) { this.browser.takeOver(); } return HitTestMode.Default; })
          .onMouse((event) => { if (event.action === MouseAction.Press) { this.browser.takeOver(); } })
          .onAxisEvent(() => { this.browser.takeOver(); })
          .onKeyEvent((event) => { if (event.type === KeyType.Down) { this.browser.takeOver(); } return false; })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
      .opacity(this.expanded && this.browser.open ? 1 : 0)
      .hitTestBehavior(this.expanded && this.browser.open ? HitTestMode.Default : HitTestMode.None)
      .enabled(this.expanded && this.browser.open)
      .accessibilityLevel(this.expanded && this.browser.open ? 'auto' : 'no-hide-descendants')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

@Component
export struct BrowserStatusCard {
  @ObjectLink browser: BrowserSession;
  onOpen: () => void = () => {};
  build() {
    Column({ space: Space.sm }) {
      if (this.browser.permissionPending) {
        Text(t('允许启用应用内浏览器？')).id('browser-permission-title').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(this.browser.permissionReason).fontSize(13).fontColor($r('app.color.text_secondary'))
        Text(this.browser.permissionUrl).fontSize(12).maxLines(2).fontColor($r('app.color.text_secondary'))
        Text(t('你可以随时接管浏览器，也可以在设置中关闭。网页内容会发送给当前模型。')).fontSize(12).fontColor($r('app.color.text_secondary'))
        Row({ space: Space.sm }) {
          Button(t('保持关闭')).id('browser-permission-deny').attributeModifier(Btn.plainSmall).layoutWeight(1).enabled(!this.browser.permissionSaving)
            .onClick(async () => { try { await this.browser.setEnabled(false); } catch (_) { /* The browser exposes the save error. */ } })
          Button(t('允许并启用')).id('browser-permission-allow').attributeModifier(Btn.primarySmall).layoutWeight(1).enabled(!this.browser.permissionSaving)
            .onClick(async () => { try { await this.browser.setEnabled(true); } catch (_) { /* The browser exposes the save error. */ } })
        }.width('100%')
      } else if (this.browser.open) {
        Button() {
          Row({ space: Space.sm }) {
            SymbolGlyph($r('sys.symbol.connection')).fontSize(18).fontColor([$r('app.color.accent')])
            Column({ space: 2 }) {
              Text(this.browser.owner === 'agent' ? t('Tinybot 正在使用浏览器') : this.browser.hasTask ? t('浏览器由你控制 · 任务已暂停') : t('浏览器由你控制'))
                .fontSize(13).fontColor($r('app.color.text_primary'))
              Text(this.browser.handoffReason || this.browser.title || this.browser.url).fontSize(12).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          }.width('100%')
        }.id('open-agent-browser').attributeModifier(Btn.plainSmall).width('100%').onClick(this.onOpen)
      }
      if (this.browser.error) {
        Text(this.browser.error).fontSize(12).fontColor($r('app.color.danger')).width('100%')
      }
    }.width('100%').padding(Space.sm).backgroundColor($r('app.color.surface_variant')).borderRadius(12)
  }
}
