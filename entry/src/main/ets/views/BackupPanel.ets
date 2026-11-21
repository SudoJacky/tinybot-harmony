import { PageStyles } from '../common/PageStyles';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { getLocale, t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { Diagnostics } from '../model/Diagnostics';
import { CloudBackup, CloudBackupItem, cloudBackupError, latestCloudBackup } from '../services/CloudBackup';
import { reviewBackupRestore } from './BackupRestoreReview';
import { AutoCloudBackup, autoCloudBackup } from '../services/AutoCloudBackup';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';
import { BackupLoginRequired, huaweiAccount } from '../services/HuaweiAccount';
import { NativeData } from '../services/NativeData';
import { DeviceSyncStore, SyncDevice, trustedDevices } from '../services/DeviceSyncStore';
import { sendDeviceData, receiveDeviceData } from '../services/DeviceTransfer';
import { withBackupOperation } from '../services/Backup';

@Component
export struct BackupPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onWebDav: () => void = () => {};
  onLogin: () => void = () => {};
  @StorageProp('tinybot.foreground') @Watch('foregroundChanged') private foreground: boolean = true;
  @State private automatic: AutoCloudBackup = autoCloudBackup;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private status: string = '';
  @State private backupDate: string = '';
  @State private needsLogin: boolean = false;
  @State private recoveryPending: boolean = false;
  @State private versions: CloudBackupItem[] = [];
  @State private showVersions: boolean = false;
  private visible: boolean = false;
  @State private devices: SyncDevice[] = [];
  @State private sending: boolean = false;
  private deviceStore?: DeviceSyncStore;
  private transferring: boolean = false;
  private reading?: Promise<void>;
  private statusError: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.recoveryPending = NativeData.forFilesDir(this.context().filesDir)?.autoBackupReady() === false;
    this.refreshStatus();
  }
  aboutToDisappear(): void {
    this.visible = false;
    if (!this.transferring) { this.closeDeviceStore(); }
  }
  private async closeDeviceStore(): Promise<void> {
    const store = this.deviceStore; this.deviceStore = undefined;
    if (store) {
      try { await store.close(); }
      catch (error) { Diagnostics.log('error', 'sync', 'device_store_close_failed', undefined, error as Error); }
    }
  }
  private async foregroundChanged(): Promise<void> {
    if (!this.foreground || !this.visible || this.busy) { return; }
    await this.reading;
    if (this.foreground && this.visible && !this.busy) { await this.refreshStatus(); }
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private locked(): boolean { return this.app.sharedBusy || this.busy; }
  private refreshStatus(): Promise<void> {
    if (!this.reading) { this.reading = this.readStatus().finally(() => { this.reading = undefined; }); }
    return this.reading;
  }
  private async readStatus(): Promise<void> {
    try {
      const items = await CloudBackup.list(this.context());
      if (!this.visible) { return; }
      this.automatic.confirmUploaded(items);
      this.versions = items.filter((item) => item.location === 2 || item.location === 3);
      if (this.statusError) { this.error = ''; this.statusError = false; }
      const latest = latestCloudBackup(items);
      this.backupDate = latest ? new Date(latest.createdAt).toLocaleString(getLocale()) : '';
    } catch (error) {
      Diagnostics.log('warn', 'backup', 'cloud_list_failed', undefined, error as Error);
      if (this.visible && (!this.error || this.statusError)) { this.error = cloudBackupError(error as Error); this.statusError = true; }
    }
  }
  private async chooseRestore(): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; this.needsLogin = false; this.versions = []; this.showVersions = false;
    try {
      await huaweiAccount.backupOpenID(this.context());
      if (!await CloudBackup.sync()) { throw new Error(t('云端同步尚未完成，请稍后重试恢复备份。')); }
      await this.reading;
      this.versions = (await CloudBackup.list(this.context())).filter((item) => item.location === 2 || item.location === 3);
      this.showVersions = true;
      if (!this.versions.length) { this.error = t('云端暂无可恢复的备份，请先在原设备完成备份。'); }
    } catch (error) { this.error = cloudBackupError(error as Error); this.needsLogin = error instanceof BackupLoginRequired; }
    finally { this.busy = false; }
  }
  private async cloud(restore: boolean, name: string = ''): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; this.statusError = false; this.needsLogin = false;
    this.status = restore ? t('正在从云端下载并恢复备份…') : t('正在备份到云端…');
    try {
      await this.reading;
      this.error = ''; this.statusError = false;
      const context = this.context();
      if (restore) {
        const data = name ? await CloudBackup.restore(context, name, this.app.exportSnapshot(), 'copy') :
          await CloudBackup.restoreLatest(context, this.app.exportSnapshot());
        if (!await reviewBackupRestore(this.getUIContext(), data)) { this.status = ''; return; }
        if (!await this.app.importSnapshot(data)) { throw new Error(this.app.error); }
        NativeData.forFilesDir(context.filesDir)?.allowAutoBackup();
        this.recoveryPending = false;
        if (this.visible) { this.status = t('备份已恢复，已保留本机已有数据。'); }
      } else {
        const result = await CloudBackup.create(context, this.app.configurationSnapshot());
        if (result === 'uploaded') { NativeData.forFilesDir(context.filesDir)?.allowAutoBackup(); this.recoveryPending = false; }
        if (this.visible) {
          this.status = result === 'uploaded' ? t('备份已上传到云端。') : result === 'blocked' ?
            t('已有配置备份等待上传。上传完成后，再创建新版本。') : t('备份已保存在本机，等待上传。请联网后再次备份。');
        }
      }
    } catch (error) {
      if (this.visible) {
        this.needsLogin = error instanceof BackupLoginRequired;
        this.error = cloudBackupError(error as Error); this.status = '';
      }
    } finally {
      if (!this.needsLogin) { await this.refreshStatus(); }
      this.busy = false;
    }
  }

  private async discover(sending: boolean): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; this.status = ''; this.needsLogin = false; this.devices = [];
    try {
      const context = this.context(), devices = await trustedDevices(context);
      if (!this.deviceStore) { this.deviceStore = await DeviceSyncStore.open(context); }
      this.sending = sending; this.devices = devices;
      if (!devices.length) { this.status = t('未发现可信设备，请确认两端已组网并安装 Tinybot。'); }
    } catch (error) {
      this.error = (error as Error).message;
      Diagnostics.log('error', 'sync', 'device_discovery_failed', undefined, error as Error);
    }
    finally { this.busy = false; if (!this.visible) { await this.closeDeviceStore(); } }
  }

  private async transfer(device: SyncDevice): Promise<void> {
    if (this.locked()) { return; }
    this.transferring = true; this.busy = true; this.devices = []; this.error = ''; this.status = t('正在传输设备数据…');
    try {
      await withBackupOperation(async () => {
        const context = this.context(), store = this.deviceStore;
        if (!store) { throw new Error('Device transfer session is closed'); }
        if (this.sending) {
          await sendDeviceData(context, store, device.id, this.app.exportSnapshot());
          this.status = t('数据已发送。请在对方设备选择从本机接收。');
        } else {
          let summary = '';
          const imported = await this.app.receiveFromDevice(async (snapshot) => {
            const result = await receiveDeviceData(context, store, device.id, snapshot);
            summary = t('已合并 {0} 个会话，其中 {1} 个分支，已写入 {2} 个文件。', [result.threads, result.branches, result.files]);
            return result.data;
          });
          if (!imported) { throw new Error(this.app.error || this.app.saveError || t('当前无法导入数据。')); }
          this.status = summary;
        }
      });
    } catch (error) {
      this.error = (error as Error).message; this.status = '';
      Diagnostics.log('error', 'sync', 'device_transfer_failed', undefined, error as Error);
    } finally { this.transferring = false; this.busy = false; if (!this.visible) { await this.closeDeviceStore(); } }
  }

  @Builder
  backupTab() {
    Scroll() {
      Column({ space: Space.md }) {
        SectionHeader({ title: t('设备间数据同步'), caption: t('两端分别点发送和接收。发送完成后，在接收端点选发送设备。') })
        GroupCard() {
          Column() {
            NavRow({ title: t('发送到其他设备'), icon: $r('sys.symbol.arrow_up'), compId: 'device-sync-send',
              disabled: this.locked(), onTap: () => this.discover(true) })
            RowDivider()
            NavRow({ title: t('从其他设备接收'), icon: $r('sys.symbol.arrow_down'), compId: 'device-sync-receive',
              disabled: this.locked(), onTap: () => this.discover(false) })
            ForEach(this.devices, (device: SyncDevice) => {
              NavRow({ title: device.name, icon: $r('sys.symbol.arrow_left_arrow_right'), disabled: this.locked(),
                onTap: () => this.transfer(device) })
            }, (device: SyncDevice) => device.id)
          }
        }
        SectionHeader({ title: t('第三方备份位置') })
        GroupCard() {
          NavRow({ title: t('WebDAV'), subtitle: t('使用自己的 WebDAV 服务器手动备份和恢复'),
            compId: 'webdav-backup-settings', icon: $r('sys.symbol.cloud'), disabled: this.locked(), onTap: () => this.onWebDav() })
        }
        SectionHeader({ title: t('华为云空间') })
        GroupCard() {
          Column() {
            NavRow({ title: t('备份'), subtitle: t('只上传配置与加密连接凭据，保留最近 3 个配置版本'),
              compId: 'create-cloud-backup', animatedIcon: 'backup', disabled: this.locked(), onTap: () => this.cloud(false) })
            RowDivider()
            NavRow({ title: t('恢复备份'), subtitle: t('选择设备与版本，确认恢复内容'),
              compId: 'restore-cloud-backup', animatedIcon: 'restore', disabled: this.locked(), onTap: () => this.chooseRestore() })
          }
        }
        if (this.showVersions) {
          GroupCard() {
            Column() {
              ForEach(this.versions, (item: CloudBackupItem) => {
                NavRow({ title: new Date(item.createdAt).toLocaleString(getLocale()),
                  subtitle: item.name.startsWith('tinybot-config-') ? t('配置备份 · 设备 {0}', [item.deviceId?.slice(0, 8) || '']) : t('旧版备份'),
                  icon: $r('sys.symbol.clock'), disabled: this.locked(), onTap: () => this.cloud(true, item.name) })
              }, (item: CloudBackupItem) => item.name)
            }
          }
        }
        if (this.backupDate) {
          Text(t('云端备份 · {0}', [this.backupDate])).id('cloud-backup-date').fontSize(13)
            .fontColor($r('app.color.text_secondary')).width('100%')
        }
        Text(this.recoveryPending ? t('数据恢复期间已暂停自动备份。恢复云备份或手动完成新备份后，将继续自动备份。') : this.automatic.status)
          .id('auto-cloud-backup-status').fontSize(13)
          .fontColor($r('app.color.text_secondary')).width('100%')
        if (this.busy) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color(this.appearance.accent)
            Text(this.status).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.width('100%')
        } else if (this.status) {
          Banner({ text: this.status, danger: false, compId: 'cloud-backup-status' })
        }
        if (this.error) { Banner({ text: this.error, compId: 'cloud-backup-error' }) }
        if (this.needsLogin) {
          Button(t('登录华为账号')).attributeModifier(Btn.tonal).id('cloud-backup-login').onClick(() => this.onLogin())
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl }).attributeModifier(PageStyles.form)
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }
  build() { this.backupTab() }
}
