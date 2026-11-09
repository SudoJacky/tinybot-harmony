import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { PageStyles } from '../common/PageStyles';
import { Btn, Space, Styles } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { BackupLoginRequired } from '../services/HuaweiAccount';
import { WebDavBackup } from '../services/WebDavBackup';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@Component
export struct WebDavBackupPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onLogin: () => void = () => {};
  @State private directory: string = '';
  @State private username: string = '';
  @State private password: string = '';
  @State private configured: boolean = false;
  @State private dirty: boolean = false;
  @State private busy: boolean = true;
  @State private needsLogin: boolean = false;
  @State private error: string = '';
  @State private status: string = '';

  async aboutToAppear(): Promise<void> {
    try { await this.load(); }
    catch (error) { this.settingsError(error as Error); }
    finally { this.busy = false; }
  }

  private async load(): Promise<void> {
    const saved = await WebDavBackup.settings();
    this.configured = saved !== undefined;
    this.directory = saved?.directory || '';
    this.username = saved?.username || '';
    this.password = '';
    this.dirty = false;
  }

  private settingsError(error: Error): void {
    Diagnostics.log('warn', 'backup', 'webdav_settings_failed', undefined, error);
    this.error = error.message;
  }

  private changed(): void {
    this.dirty = true;
    this.error = '';
    this.status = '';
    this.needsLogin = false;
  }

  private async save(clear: boolean): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.needsLogin = false;
    this.status = '';
    this.error = '';
    try {
      if (clear) { await WebDavBackup.clear(); }
      else { await WebDavBackup.save(this.directory, this.username, this.password); }
      await this.load();
      this.status = clear ? t('已移除本机 WebDAV 设置。') : t('已保存 WebDAV 设置。');
    } catch (error) { this.settingsError(error as Error); }
    finally { this.busy = false; }
  }

  private locked(): boolean {
    return this.busy || this.app.busy || !this.configured || this.dirty;
  }

  private async transfer(restore: boolean): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true;
    this.needsLogin = false;
    this.error = '';
    this.status = t('正在处理备份…');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (restore) {
        const restored = await WebDavBackup.restore(context, this.app.exportSnapshot());
        if (!await this.app.importSnapshot(restored)) { throw new Error(this.app.error || this.app.saveError); }
        this.status = t('备份已恢复，已保留本机已有数据。');
      } else {
        await WebDavBackup.create(context, this.app.exportSnapshot());
        this.status = t('备份已上传到 WebDAV。');
      }
    } catch (error) {
      this.status = '';
      this.needsLogin = error instanceof BackupLoginRequired;
      this.error = (error as Error).message;
    } finally { this.busy = false; }
  }

  build() {
    Scroll() {
      Column({ space: Space.md }) {
        Text(t('使用已有的 HTTPS WebDAV 目录。WebDAV 账号和密码保存在本机。备份使用华为账号加密连接凭据，对话和文件以明文保存在服务器上。'))
          .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary')).width('100%')
        Column({ space: Space.sm }) {
          Text(t('WebDAV 目录地址')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: this.directory, placeholder: 'https://example.com/dav/tinybot/' })
            .id('webdav-directory').attributeModifier(Styles.input).onChange((value: string) => { this.directory = value; this.changed(); })
          Text(t('WebDAV 账号')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: this.username }).id('webdav-username').attributeModifier(Styles.input)
            .onChange((value: string) => { this.username = value; this.changed(); })
          Text(t('WebDAV 密码或应用专用密码')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: this.password, placeholder: this.configured ? t('留空保留当前密码') : '' })
            .type(InputType.Password).showPasswordIcon(true).id('webdav-password').attributeModifier(Styles.input)
            .onChange((value: string) => { this.password = value; this.changed(); })
          Row({ space: Space.sm }) {
            Button(t('保存')).attributeModifier(Btn.primary).id('webdav-save').enabled(this.dirty).onClick(() => this.save(false))
            if (this.configured) {
              Button(t('移除本机设置')).attributeModifier(Btn.tonal).id('webdav-clear').onClick(() => this.save(true))
            }
          }.width('100%')
        }.width('100%').enabled(!this.busy)
        GroupCard() {
          Column() {
            NavRow({ title: t('备份'), subtitle: t('上传快照并替换 WebDAV 目录中的上一份备份'),
              compId: 'create-webdav-backup', icon: $r('sys.symbol.cloud'), disabled: this.locked(), onTap: () => this.transfer(false) })
            RowDivider()
            NavRow({ title: t('恢复备份'), subtitle: t('下载 WebDAV 备份并合并到本机'),
              compId: 'restore-webdav-backup', icon: $r('sys.symbol.arrow_clockwise'), disabled: this.locked(), onTap: () => this.transfer(true) })
          }
        }
        if (this.busy) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color(this.appearance.accent)
            Text(this.status).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.width('100%')
        } else if (this.status) {
          Banner({ text: this.status, danger: false, compId: 'webdav-status' })
        }
        if (this.error) { Banner({ text: this.error, compId: 'webdav-error' }) }
        if (this.needsLogin) {
          Button(t('登录华为账号')).attributeModifier(Btn.tonal).id('webdav-login').onClick(() => this.onLogin())
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
        .attributeModifier(PageStyles.form)
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }
}
