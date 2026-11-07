import { PageStyles } from '../common/PageStyles';
import { util } from '@kit.ArkTS';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Space, Styles } from '../common/Theme';
import { Banner, GroupCard, NavRow, SectionHeader, SwitchRow, BottomBar, EmptyState } from '../common/Widgets';
import { MailAccount } from '../model/Mail';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';
import { MailAccounts } from '../services/MailAccounts';
import { MailService } from '../services/MailService';
import { Cancellation } from '../services/Cancellation';
@Component
export struct MailSettingsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('activityChanged') private foreground: boolean = true;
  @State private accounts: MailAccount[] = [];
  @State private editing: boolean = false;
  @State private accountId: string = '';
  @State private name: string = '';
  @State private host: string = '';
  @State private port: string = '993';
  @State private username: string = '';
  @State private secret: string = '';
  @State private accessEnabled: boolean = false;
  @State private allowBody: boolean = false;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private notice: string = '';
  private cancellation: Cancellation = new Cancellation();
  private mounted: boolean = false;
  private store: MailAccounts = new MailAccounts();
  aboutToAppear(): void { this.mounted = true; this.reload(); }
  aboutToDisappear(): void { this.mounted = false; this.cancellation.cancel(); this.secret = ''; }
  private activityChanged(): void { if (!this.foreground) { this.cancellation.cancel(); this.secret = ''; } }
  private async reload(): Promise<void> {
    try { const accounts = await this.store.list(); if (this.mounted) { this.accounts = accounts; } }
    catch (error) { this.report(error as Error); }
  }
  private report(error: Error): void {
    if (this.mounted) { this.error = error.message; }
    Diagnostics.log('error', 'mail', 'settings_failed', {}, error);
  }
  private edit(account?: MailAccount): void {
    this.accountId = account?.id || ''; this.name = account?.name || ''; this.host = account?.host || '';
    this.port = String(account?.port || 993); this.username = account?.username || '';
    this.accessEnabled = account?.enabled === true; this.allowBody = account?.allowBody === true;
    this.secret = ''; this.error = ''; this.notice = ''; this.editing = true;
  }
  private async save(check: boolean): Promise<void> {
    if (this.busy || !this.foreground) { return; } this.busy = true; this.error = ''; this.notice = ''; this.cancellation = new Cancellation();
    const cancellation = this.cancellation;
    try {
      const account: MailAccount = { id: this.accountId || util.generateRandomUUID(), name: this.name.trim(), host: this.host.trim().toLowerCase(), port: Number(this.port),
        username: this.username.trim(), enabled: this.accessEnabled, allowBody: this.allowBody };
      await this.store.save(account, this.secret); this.secret = ''; this.accountId = account.id;
      await this.reload(); cancellation.check(); this.notice = t('邮箱连接已保存');
      if (check) {
        const snapshot = await new MailService(this.store).query({ accountId: account.id, folder: 'INBOX', limit: 1 }, cancellation);
        cancellation.check(); this.notice = t('连接成功：收件箱 {0} 封邮件，{1} 封未读', [snapshot.total, snapshot.unread]);
      }
    } catch (error) { if (!cancellation.cancelled) { this.report(error as Error); } }
    finally { this.secret = ''; this.busy = false; }
  }
  private async remove(): Promise<void> {
    if (this.busy || !this.accountId) { return; } this.busy = true; this.error = ''; this.notice = '';
    try { await this.store.remove(this.accountId); this.secret = ''; this.editing = false; await this.reload(); }
    catch (error) { this.report(error as Error); } finally { this.busy = false; }
  }
  @Builder
  editor() {
    Column({ space: Space.md }) {
      Text(t('连接名称')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: this.name, placeholder: t('连接名称，例如工作邮箱') }).attributeModifier(Styles.input).id('mail-name').onChange((value: string) => { this.name = value; })
      Text(t('IMAP 服务器')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: this.host, placeholder: t('IMAP 服务器，例如 imap.example.com') }).attributeModifier(Styles.input).id('mail-host').onChange((value: string) => { this.host = value; })
      Text(t('TLS 端口')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: this.port, placeholder: t('TLS 端口，通常为 993') }).type(InputType.Number).attributeModifier(Styles.input).id('mail-port').onChange((value: string) => { this.port = value; })
      Text(t('邮箱登录账号')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: this.username, placeholder: t('邮箱登录账号') }).attributeModifier(Styles.input).id('mail-username').onChange((value: string) => { this.username = value; })
      Text(t('授权码或应用专用密码')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: this.secret, placeholder: this.accountId ? t('授权码，留空保留已保存的授权码') : t('邮箱授权码或应用专用密码') }).type(InputType.Password).showPasswordIcon(true)
        .attributeModifier(Styles.input).id('mail-secret').onChange((value: string) => { this.secret = value; })
      GroupCard() {
        Column() {
          SwitchRow({ title: t('允许助手和卡片读取邮件'), subtitle: t('邮件标题和发件人可发送给当前模型。'), icon: $r('sys.symbol.doc_text'), isOn: this.accessEnabled,
            onChange: (value: boolean) => { this.accessEnabled = value; } })
          SwitchRow({ title: t('允许读取邮件正文'), subtitle: t('开启后，助手可按任务需要读取正文并发送给当前模型。'), icon: $r('sys.symbol.doc_plaintext'), isOn: this.allowBody,
            onChange: (value: boolean) => { this.allowBody = value; } })
        }
      }
      Text(t('请先在邮箱服务商处开启 IMAP，并获取授权码。仅支持 TLS 加密连接；账号和授权码只保存在当前设备，不参与备份。'))
        .fontSize(12).fontColor($r('app.color.text_secondary'))

      if (this.accountId) { Button(t('移除邮箱连接')).attributeModifier(Btn.textSmall).fontColor($r('app.color.danger')).id('mail-remove').onClick(() => { this.remove(); }) }
      Button(t('返回邮箱列表')).attributeModifier(Btn.textSmall).onClick(() => { this.secret = ''; this.editing = false; this.error = ''; this.notice = ''; })
    }.enabled(!this.busy).width('100%')
  }
  build() {
    Column() {
      if (this.error) { Banner({ text: this.error, compId: 'mail-error' }).padding({ left: Space.page, right: Space.page, top: Space.sm }) }
      if (this.notice) { Banner({ text: this.notice, danger: false, compId: 'mail-notice' }).padding({ left: Space.page, right: Space.page, top: Space.sm }) }
    Scroll() {
      Column({ space: Space.md }) {
        Text(t('读取邮箱中的未读数量、最近邮件和指定邮件，为对话和生活看板提供数据。不会发送、删除邮件或改变已读状态。'))
          .fontSize(13).fontColor($r('app.color.text_secondary'))
        if (this.editing) { this.editor() }
        else {
          SectionHeader({ title: t('邮箱连接') })
          if (this.accounts.length === 0) {
            EmptyState({ icon: $r('sys.symbol.doc_text'), title: t('还没有邮箱连接'), caption: t('连接邮箱后，可让助手读取未读数量和邮件。') })
          }
          ForEach(this.accounts, (account: MailAccount) => {
            GroupCard() {
              NavRow({ title: account.name, subtitle: account.username, value: account.enabled ? t('已启用') : t('已停用'), icon: $r('sys.symbol.doc_text'), onTap: () => this.edit(account) })
            }
          }, (account: MailAccount) => account.id)
          Button(t('添加邮箱连接')).attributeModifier(Btn.primary).id('mail-add').enabled(!this.busy).onClick(() => this.edit())
        }
        if (this.busy) { LoadingProgress().width(28).height(28) }
      }.width('100%').padding(Space.page).alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).width('100%').align(Alignment.Top)
    if (this.editing) { BottomBar() {
      Row({ space: Space.md }) {
        Button(t('保存')).attributeModifier(Btn.primary).id('mail-save').onClick(() => { this.save(false); })
        Button(t('保存并检查连接')).attributeModifier(Btn.tonal).id('mail-test').enabled(this.accessEnabled).onClick(() => { this.save(true); })
      }.width('100%').enabled(!this.busy)
    } }
    }.height('100%').width('100%').attributeModifier(PageStyles.form).backgroundColor($r('app.color.page_background'))
  }
}
