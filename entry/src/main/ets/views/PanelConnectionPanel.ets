import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { PanelEntry } from '../model/LifePanel';
import { LifePanels } from '../services/LifePanels';
import { Cancellation } from '../services/Cancellation';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';

@Component
export struct PanelConnectionPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop entry: PanelEntry;
  onConnected: () => void = () => {};
  @State private secret: string = '';
  @State private connected: boolean = false;
  @State private busy: boolean = false;
  @State private error: string = '';
  private cancellation: Cancellation = new Cancellation();
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private credentials() { return new LifePanels(this.context().getApplicationContext().filesDir).credentials(this.entry.workspaceId); }
  aboutToAppear(): void { this.run('status'); }
  aboutToDisappear(): void { this.cancellation.cancel(); this.secret = ''; }
  private async run(action: string): Promise<void> {
    if (this.busy) { return; } this.busy = true; this.error = '';
    try {
      const credentials = this.credentials(), source = this.entry.panel.definition.source!;
      if (action === 'save') { await credentials.save(this.entry.panel.id, source, this.secret); this.secret = ''; }
      else if (action === 'login') { await credentials.login(this.entry.panel.id, source, this.context(), this.cancellation); }
      else if (action === 'disconnect') { await credentials.disconnect(this.entry.panel.id); }
      this.connected = await credentials.connected(this.entry.panel.id, source);
      if (action === 'save' || action === 'login') { this.onConnected(); }
    } catch (error) {
      if (!this.cancellation.cancelled) { this.error = (error as Error).message; Diagnostics.log('error', 'life-panel', 'connection_failed', {}, error as Error); }
    } finally { this.busy = false; }
  }
  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.entry.panel.definition.title).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(this.entry.panel.definition.source!.url || '').fontSize(12).fontColor($r('app.color.text_secondary'))
        Text(this.connected ? t('已连接') : t('未连接')).fontSize(14).fontColor($r('app.color.text_secondary'))
        Text(t('凭据仅保存在当前设备的安全存储中，不会提供给 Agent 或包含在卡片备份中。'))
          .fontSize(12).fontColor($r('app.color.text_secondary'))
        if (this.entry.panel.definition.source!.auth!.type === 'oauth') {
          Text(t('使用系统浏览器授权。服务需要支持公开客户端和 PKCE，注册回调地址为：{0}', ['tinybot-harmony://oauth/callback']))
            .fontSize(12).fontColor($r('app.color.text_secondary'))
          Button(t('OAuth 登录')).attributeModifier(Btn.primary).enabled(!this.busy).onClick(() => { this.run('login'); })
        } else {
          TextInput({ text: this.secret, placeholder: this.entry.panel.definition.source!.auth!.type === 'bearer' ? 'Bearer Token' : 'API Key' })
            .type(InputType.Password).showPasswordIcon(true).id('panel-api-secret').enabled(!this.busy)
            .onChange((value: string) => { this.secret = value; })
          Button(t('保存凭据')).attributeModifier(Btn.primary).enabled(!this.busy && !!this.secret.trim()).onClick(() => { this.run('save'); })
        }
        if (this.connected) {
          Button(t('断开连接')).attributeModifier(Btn.tonal).enabled(!this.busy).onClick(() => { this.run('disconnect'); })
        }
        if (this.busy) { LoadingProgress().width(28).height(28) }
        if (this.error) { Banner({ text: this.error }) }
      }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%')
  }
}
