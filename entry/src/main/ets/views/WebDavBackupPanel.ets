import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { PageStyles } from '../common/PageStyles';
import { Btn, Font, Space, Styles } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';
import { Diagnostics } from '../model/Diagnostics';
import { getLocale, t } from '../model/I18n';
import { BackupSnapshot } from '../model/BackupSnapshots';
import { reviewBackupRestore } from './BackupRestoreReview';
import { BackupLoginRequired, huaweiAccount } from '../services/HuaweiAccount';
import { WebDavBackup } from '../services/WebDavBackup';
import { clearWebDavConnection, saveWebDavConnection, webDavSettings, WebDavSettings } from '../services/WebDavConnection';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@Component
export struct WebDavBackupPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onLogin: () => void = () => {};
  @State private connections: WebDavSettings[] = [];
  @State private name: string = '';
  @State private directory: string = '';
  @State private username: string = '';
  @State private password: string = '';
  @State private saved?: WebDavSettings = undefined;
  @State private dirty: boolean = false;
  @State private busy: boolean = true;
  @State private needsLogin: boolean = false;
  @State private error: string = '';
  @State private status: string = '';
  @State private transferFeedback: boolean = false;
  @State private versions: BackupSnapshot[] = [];

  async aboutToAppear(): Promise<void> {
    try {
      this.connections = await webDavSettings();
      this.edit(this.connections[0]);
    }
    catch (error) { this.settingsError(error as Error); }
    finally { this.busy = false; }
  }

  private edit(saved?: WebDavSettings): void {
    this.saved = saved;
    this.name = saved?.name || '';
    this.directory = saved?.directory || '';
    this.username = saved?.username || '';
    this.password = '';
    this.dirty = false;
    this.error = '';
    this.status = '';
    this.needsLogin = false;
    this.transferFeedback = false;
    this.versions = [];
  }

  private choose(saved?: WebDavSettings): void {
    if (this.busy || (saved && this.saved?.id === saved.id)) { return; }
    if (!this.dirty) { this.edit(saved); return; }
    this.getUIContext().showAlertDialog({
      systemMaterial: this.appearance.surface, title: t('放弃未保存的修改？'),
      message: this.name.trim() || t('添加 WebDAV 连接'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('放弃修改'), action: () => this.edit(saved) }
    });
  }

  private settingsError(error: Error): void {
    Diagnostics.log('warn', 'backup', 'webdav_settings_failed', undefined, error);
    this.status = '';
    this.error = error.message;
  }

  private changed(): void {
    const dirty = this.name !== (this.saved?.name || '') || this.directory !== (this.saved?.directory || '') ||
      this.username !== (this.saved?.username || '') || this.password.length > 0;
    if (!dirty && !this.dirty) { return; }
    this.dirty = dirty;
    this.error = '';
    this.transferFeedback = false;
    this.status = '';
    this.needsLogin = false;
  }

  private async save(clear: boolean): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.needsLogin = false;
    this.transferFeedback = false;
    this.status = clear ? t('正在移除连接…') : t('正在保存连接…');
    this.error = '';
    try {
      const id = this.saved?.id || '';
      if (clear) {
        await clearWebDavConnection(id);
        this.connections = this.connections.filter((item) => item.id !== id);
        this.edit();
      } else {
        const saved = await saveWebDavConnection(id, this.name, this.directory, this.username, this.password);
        this.connections = id ? this.connections.map((item) => item.id === id ? saved : item) : this.connections.concat(saved);
        this.edit(saved);
      }
      this.status = clear ? t('已移除 WebDAV 连接。') : t('已保存 WebDAV 设置。');
    } catch (error) { this.settingsError(error as Error); }
    finally { this.busy = false; }
  }

  private locked(): boolean {
    return this.busy || this.app.sharedBusy || !this.saved || this.dirty;
  }

  private confirmClear(): void {
    if (this.busy || !this.saved) { return; }
    this.getUIContext().showAlertDialog({
      systemMaterial: this.appearance.surface, title: t('移除 WebDAV 连接？'),
      message: t('移除「{0}」后，使用此连接的项目目录需要重新添加。服务器上的文件和备份会保留。', [this.saved.name]),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('移除'), fontColor: $r('app.color.danger'), action: () => this.save(true) }
    });
  }

  private async chooseRestore(): Promise<void> {
    if (this.locked() || !this.saved) { return; }
    this.busy = true; this.error = ''; this.transferFeedback = true; this.versions = []; this.needsLogin = false;
    try {
      await huaweiAccount.backupOpenID(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.versions = await WebDavBackup.list(this.saved.id);
      if (!this.versions.length) { this.error = t('WebDAV 目录中没有可恢复的备份（HTTP 404）。'); }
    } catch (error) { this.error = (error as Error).message; this.needsLogin = error instanceof BackupLoginRequired; }
    finally { this.busy = false; }
  }
  private async transfer(restore: boolean, name?: string): Promise<void> {
    const saved = this.saved;
    if (!saved || this.locked()) { return; }
    this.busy = true;
    this.needsLogin = false;
    this.error = '';
    this.transferFeedback = true;
    this.status = restore ? t('正在下载并恢复 WebDAV 备份…') : t('正在上传 WebDAV 备份…');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (restore) {
        const restored = await WebDavBackup.restore(context, this.app.exportSnapshot(), saved.id, name, 'copy');
        if (!await reviewBackupRestore(this.getUIContext(), restored)) { this.status = ''; return; }
        if (!await this.app.importSnapshot(restored)) { throw new Error(this.app.error || this.app.saveError); }
        this.status = t('备份已恢复，已保留本机已有数据。');
      } else {
        await WebDavBackup.create(context, this.app.configurationSnapshot(), saved.id);
        this.status = t('备份已上传到 WebDAV。');
      }
    } catch (error) {
      this.status = '';
      this.needsLogin = error instanceof BackupLoginRequired;
      this.error = (error as Error).message;
    } finally { this.busy = false; }
  }

  @Builder
  connectionList() {
    SectionHeader({ title: t('WebDAV 连接') })
    GroupCard() {
      Column() {
        ForEach(this.connections, (connection: WebDavSettings) => {
          NavRow({ title: connection.name, subtitle: connection.username + '\n' + connection.directory, icon: $r('sys.symbol.cloud'),
            trailing: 'select', active: this.saved?.id === connection.id,
            compId: 'webdav-connection-' + connection.id, disabled: this.busy, onTap: () => this.choose(connection) })
          RowDivider()
        }, (connection: WebDavSettings) => connection.id + ':' + (connection.grantId || '') + ':' + connection.name)
        NavRow({ title: t('添加 WebDAV 连接'), icon: $r('sys.symbol.plus'), compId: 'webdav-add-connection', accent: true,
          disabled: this.busy, onTap: () => this.choose() })
      }
    }
  }

  @Builder
  fieldLabel(label: string) {
    Text(label).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
      .fontColor($r('app.color.text_secondary')).width('100%').accessibilityLevel('no')
  }

  @Builder
  connectionForm() {
    Row({ space: Space.sm }) {
      Text(this.saved ? t('连接设置') : t('添加 WebDAV 连接')).fontFamily(this.appearance.fontFamily)
        .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      if (this.saved || this.dirty) {
        Text(this.dirty ? t('有未保存的修改') : t('已保存')).id('webdav-connection-status')
          .fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
          .fontColor(this.dirty ? $r('app.color.text_tertiary') : this.appearance.accent)
      }
    }.width('100%').padding({ left: Space.xs, right: Space.xs, top: Space.lg, bottom: Space.sm })
    GroupCard() {
      Column({ space: Space.lg }) {
        Column({ space: Space.md }) {
          Column({ space: Space.xs }) {
            this.fieldLabel(t('连接名称'))
            TextInput({ text: this.name, placeholder: t('例如：坚果云、团队文件') }).id('webdav-name').maxLength(64)
              .attributeModifier(Styles.input).fontFamily(this.appearance.fontFamily).accessibilityText(t('连接名称'))
              .onChange((value: string) => { this.name = value; this.changed(); })
          }.width('100%')
          Column({ space: Space.xs }) {
            this.fieldLabel(t('WebDAV 目录地址'))
            TextInput({ text: this.directory, placeholder: 'https://example.com/dav/tinybot/' })
              .id('webdav-directory').type(InputType.URL).attributeModifier(Styles.input).fontFamily(this.appearance.fontFamily)
              .accessibilityText(t('WebDAV 目录地址')).onChange((value: string) => { this.directory = value; this.changed(); })
          }.width('100%')
        }.width('100%')
        Divider().strokeWidth(0.5).color($r('app.color.divider'))
        Column({ space: Space.md }) {
          Column({ space: Space.xs }) {
            this.fieldLabel(t('WebDAV 账号'))
            TextInput({ text: this.username }).id('webdav-username').attributeModifier(Styles.input)
              .fontFamily(this.appearance.fontFamily).accessibilityText(t('WebDAV 账号'))
              .onChange((value: string) => { this.username = value; this.changed(); })
          }.width('100%')
          Column({ space: Space.xs }) {
            this.fieldLabel(t('WebDAV 密码或应用专用密码'))
            TextInput({ text: this.password, placeholder: this.saved ? t('留空保留当前密码') : '' })
              .type(InputType.Password).showPasswordIcon(true).id('webdav-password').attributeModifier(Styles.input)
              .fontFamily(this.appearance.fontFamily).accessibilityText(t('WebDAV 密码或应用专用密码'))
              .onChange((value: string) => { this.password = value; this.changed(); })
          }.width('100%')
        }.width('100%')
        Row({ space: Space.md }) {
          if (this.saved) {
            Button(t('移除连接')).attributeModifier(Btn.textSmall).fontColor($r('app.color.danger'))
              .id('webdav-clear').constraintSize({ minHeight: 44 }).onClick(() => this.confirmClear())
          }
          Button(t('保存连接')).attributeModifier(Btn.primary).id('webdav-save').layoutWeight(1)
            .enabled(this.dirty && this.name.trim().length > 0 && this.directory.trim().length > 0 &&
              this.username.trim().length > 0 && (this.saved !== undefined || this.password.length > 0))
            .onClick(() => this.save(false))
        }.width('100%')
      }.width('100%').padding(Space.lg).enabled(!this.busy)
    }
  }

  @Builder
  backupVersions() {
    SectionHeader({ title: t('可恢复的备份') })
    GroupCard() {
      Column() {
        ForEach(this.versions, (item: BackupSnapshot, index: number) => {
          if (index > 0) { RowDivider() }
          NavRow({ title: item.createdAt ? new Date(item.createdAt).toLocaleString(getLocale()) : t('旧版备份'),
            subtitle: item.name.startsWith('tinybot-config-') ? t('配置备份 · 设备 {0}', [item.deviceId?.slice(0, 8) || '']) : t('旧版备份'),
            icon: $r('sys.symbol.clock'), disabled: this.locked(), onTap: () => this.transfer(true, item.name) })
        }, (item: BackupSnapshot) => item.name)
      }
    }
  }

  @Builder
  feedback() {
    if (this.busy && this.status) {
      Row({ space: Space.sm }) {
        LoadingProgress().width(20).height(20).color(this.appearance.accent)
        Text(this.status).id('webdav-progress').fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
          .fontColor($r('app.color.text_secondary')).layoutWeight(1)
      }.width('100%').padding({ left: Space.sm, right: Space.sm, top: Space.sm })
    } else if (this.status) {
      Banner({ text: this.status, danger: false, compId: 'webdav-status', icon: $r('sys.symbol.checkmark') })
        .margin({ top: Space.sm })
    }
    if (this.error) { Banner({ text: this.error, compId: 'webdav-error' }).margin({ top: Space.sm }) }
    if (this.needsLogin) {
      Button(t('登录华为账号')).attributeModifier(Btn.tonal).id('webdav-login').onClick(() => this.onLogin())
        .margin({ top: Space.sm })
    }
  }

  build() {
    Scroll() {
      Column() {
        if (this.connections.length > 0) { this.connectionList() }
        this.connectionForm()
        if (!this.transferFeedback) { this.feedback() }
        SectionHeader({ title: t('备份与恢复'),
          caption: this.dirty ? t('保存连接修改后即可备份或恢复。') : !this.saved ? t('保存 WebDAV 连接后即可备份或恢复。') :
            t('使用连接「{0}」。', [this.saved.name]) })
        GroupCard() {
          Column() {
            NavRow({ title: t('备份'), subtitle: t('只上传配置与加密连接凭据，保留最近 3 个配置版本'),
              compId: 'create-webdav-backup', animatedIcon: 'backup', disabled: this.locked(), onTap: () => this.transfer(false) })
            RowDivider()
            NavRow({ title: t('恢复备份'), subtitle: t('下载 WebDAV 备份并合并到本机'),
              compId: 'restore-webdav-backup', animatedIcon: 'restore', disabled: this.locked(), onTap: () => this.chooseRestore() })
          }
        }
        if (this.transferFeedback) { this.feedback() }
        if (this.versions.length > 0) { this.backupVersions() }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.xs, bottom: Space.xl })
        .attributeModifier(PageStyles.form)
    }.id('webdav-settings-scroll').width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }
}
