import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { PageStyles } from '../common/PageStyles';
import { Btn, Font, Space, Styles } from '../common/Theme';
import { Banner, BottomBar, GroupCard, NavRow, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { Cancellation } from '../services/Cancellation';
import { IMA_SETUP_URL, ImaSettings, imaClient } from '../services/ImaClient';

@Component
export struct ImaSettingsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('activityChanged') private foreground: boolean = true;
  @State private clientId: string = '';
  @State private apiKey: string = '';
  @State private accessEnabled: boolean = true;
  @State private configured: boolean = false;
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private testing: boolean = false;
  @State private error: string = '';
  @State private notice: string = '';
  private mounted: boolean = false;
  private testSignal: Cancellation = new Cancellation();

  aboutToAppear(): void { this.mounted = true; this.load(); }
  aboutToDisappear(): void { this.mounted = false; this.testSignal.cancel(); this.apiKey = ''; }
  private activityChanged(): void { if (!this.foreground) { this.testSignal.cancel(); this.apiKey = ''; } }

  private apply(settings?: ImaSettings): void {
    if (!this.mounted) { return; }
    this.configured = settings !== undefined;
    this.clientId = settings?.clientId || '';
    this.accessEnabled = settings?.enabled ?? true;
    this.apiKey = '';
    this.ready = true;
  }

  private async load(): Promise<void> {
    this.busy = true;
    try { this.apply(await imaClient.load()); }
    catch (error) { this.report(error as Error); }
    finally { this.busy = false; }
  }

  private report(error: Error): void {
    Diagnostics.log('warn', 'ima', 'settings_failed', {}, error);
    if (this.mounted) { this.error = error.message; }
  }

  private clearFeedback(): void { this.error = ''; this.notice = ''; }

  private async save(): Promise<void> {
    if (this.busy || !this.ready || !this.foreground) { return; }
    this.busy = true; this.clearFeedback();
    try {
      this.apply(await imaClient.save({ clientId: this.clientId, enabled: this.accessEnabled }, this.apiKey));
      if (this.mounted) { this.notice = t('腾讯 ima 连接已保存。'); }
    } catch (error) { this.report(error as Error); }
    finally { this.busy = false; }
  }

  private async test(): Promise<void> {
    if (this.busy || !this.ready || !this.foreground) { return; }
    this.busy = true; this.testing = true; this.clearFeedback();
    const cancellation = new Cancellation();
    this.testSignal = cancellation;
    try {
      await imaClient.test({ clientId: this.clientId, enabled: this.accessEnabled }, this.apiKey, cancellation);
      if (this.mounted && !cancellation.cancelled) { this.notice = t('腾讯 ima 连接成功。'); }
    } catch (error) {
      if (!cancellation.cancelled) { this.report(error as Error); }
    } finally { this.busy = false; this.testing = false; }
  }

  private async remove(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.clearFeedback();
    try {
      await imaClient.remove();
      this.apply();
      if (this.mounted) { this.notice = t('腾讯 ima 连接已移除。'); }
    } catch (error) { this.report(error as Error); }
    finally { this.busy = false; }
  }

  private async openSetup(): Promise<void> {
    try {
      await (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .openLink(IMA_SETUP_URL, { appLinkingOnly: false });
    } catch (error) { this.report(error as Error); }
  }

  @Builder
  guide() {
    SectionHeader({ title: t('连接指南') })
    GroupCard() {
      Column() {
        NavRow({ title: t('1. 打开 ima 官方配置页'), icon: $r('sys.symbol.link'),
          subtitle: t('登录后生成 API Key，并复制 Client ID 和 API Key。'),
          compId: 'ima-open-setup', disabled: this.busy, onTap: () => this.openSetup() })
        RowDivider()
        Column({ space: Space.sm }) {
          Text(t('2. 返回这里，粘贴两项凭据。')).fontFamily(this.appearance.fontFamily).fontSize(Font.body)
            .fontColor($r('app.color.text_primary')).width('100%')
          Text(t('3. 点击「测试连接」，成功后点击「保存」。')).fontFamily(this.appearance.fontFamily).fontSize(Font.body)
            .fontColor($r('app.color.text_primary')).width('100%')
        }.width('100%').padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
      }
    }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: Space.md }) {
          this.guide()
          Column({ space: Space.sm }) {
            Text('Client ID').fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.clientId, placeholder: 'Client ID' }).attributeModifier(Styles.input).id('ima-client-id')
              .onChange((value: string) => { this.clientId = value; this.clearFeedback(); })
            Text('API Key').fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.apiKey, placeholder: this.configured ? t('留空保留已保存的 API Key') : 'API Key' })
              .type(InputType.Password).showPasswordIcon(true).attributeModifier(Styles.input).id('ima-api-key')
              .onChange((value: string) => { this.apiKey = value; this.clearFeedback(); })
            GroupCard() {
              SwitchRow({ title: t('允许助手访问腾讯 ima'), isOn: this.accessEnabled, compId: 'ima-enabled',
                subtitle: t('搜索词、导入链接和上传的文件会发送给腾讯 ima。读取的资料可能发送给当前模型。'),
                onChange: (value: boolean) => { this.accessEnabled = value; this.clearFeedback(); } })
            }
          }.width('100%').enabled(this.ready && !this.busy)
          if (this.configured || (!this.ready && this.error)) {
            Button(t('移除腾讯 ima 连接')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
              .fontColor($r('app.color.danger')).id('ima-remove').enabled(!this.busy).onClick(() => this.remove())
          }
        }.width('100%').padding(Space.page).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      BottomBar() {
        Column({ space: Space.sm }) {
          if (this.error) { Banner({ text: this.error, compId: 'ima-error' }) }
          if (this.notice) { Banner({ text: this.notice, danger: false, compId: 'ima-notice' }) }
          Row({ space: Space.sm }) {
            Button(this.testing ? t('正在检查腾讯 ima 连接…') : t('测试连接')).fontFamily(this.appearance.fontFamily)
              .attributeModifier(Btn.tonal).layoutWeight(1).id('ima-test').onClick(() => this.test())
            Button(t('保存')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.primary).layoutWeight(1)
              .id('ima-save').onClick(() => this.save())
          }.width('100%').enabled(this.ready && this.foreground && !this.busy && this.clientId.trim().length > 0)
        }.width('100%')
      }
    }.height('100%').width('100%').attributeModifier(PageStyles.form).backgroundColor($r('app.color.page_background'))
  }
}
