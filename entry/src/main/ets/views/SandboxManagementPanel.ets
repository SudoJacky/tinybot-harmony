import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { PageStyles } from '../common/PageStyles';
import { Btn, Font, Space, Styles } from '../common/Theme';
import { Banner, GroupCard, RowDivider, SectionHeader, Segmented, SwitchRow } from '../common/Widgets';
import { t } from '../model/I18n';
import { SharedFolder } from '../model/SharedFolders';
import { storageSize } from '../model/StoragePlan';
import { RunCancelledError } from '../services/Cancellation';
import { LINUX_MEMORY, LINUX_TIMEOUTS, LinuxJobStatus, LinuxRuntimeSettingsUpdate, LinuxRuntimeSnapshot, linuxRuntime } from '../services/LinuxRuntime';
import { LinuxWorkspace, LinuxWorkspaceInfo } from '../services/LinuxWorkspace';
import { ProjectFolderAccess } from '../services/ProjectFolderAccess';

@Component
export struct SandboxManagementPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop readOnly: boolean = false;
  @Prop @Watch('scopeChanged') workspaceId: string = '';
  @Prop projectName: string = '';
  @State private runtime: LinuxRuntimeSnapshot = linuxRuntime.snapshot();
  @State private error: string = '';
  @State private workspaceError: string = '';
  @State private workspace: LinuxWorkspaceInfo = { persistent: false, mounts: [], storedBytes: 0 };
  @State private scopeReady: boolean = false;
  @State private picking: boolean = false;
  @State private folderSupported: boolean = false;
  @State private assetBytes: number = 0;
  @State private editingMemory: boolean = false;
  @State private memoryDraft: string = '';
  private unsubscribe?: () => void;

  aboutToAppear(): void {
    this.runtime = linuxRuntime.snapshot();
    this.unsubscribe = linuxRuntime.subscribe(() => {
      const previous = this.runtime.history[0]?.startedAt;
      this.runtime = linuxRuntime.snapshot();
      if (this.runtime.history[0]?.startedAt !== previous) { this.refreshWorkspace(); }
    });
    if (this.runtime.available) {
      this.folderSupported = ProjectFolderAccess.canSelectFolders() && ProjectFolderAccess.supported();
      this.refreshWorkspace();
      this.loadImageSize();
    }
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  private host(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }

  private scopedWorkspace(): LinuxWorkspace {
    return new LinuxWorkspace(this.host(), { id: this.workspaceId, project: this.projectName.length > 0 });
  }

  private scopeChanged(): void {
    this.scopeReady = false;
    this.workspace = { persistent: false, mounts: [], storedBytes: 0 };
    this.workspaceError = '';
    if (this.runtime.available && this.unsubscribe) { this.refreshWorkspace(); }
  }

  private async loadImageSize(): Promise<void> {
    try {
      const bytes = await linuxRuntime.imageSize(this.host());
      if (this.unsubscribe) { this.assetBytes = bytes; }
    } catch (error) { if (this.unsubscribe) { this.error = (error as Error).message; } }
  }

  private async refreshWorkspace(): Promise<void> {
    if (!this.workspaceId) { return; }
    const id = this.workspaceId;
    try {
      const info = await this.scopedWorkspace().info();
      if (!this.unsubscribe || id !== this.workspaceId) { return; }
      this.workspace = info;
      this.scopeReady = true;
    } catch (error) {
      if (!this.unsubscribe || id !== this.workspaceId) { return; }
      this.scopeReady = false;
      this.workspaceError = (error as Error).message;
    }
  }

  private async editWorkspace(change: (workspace: LinuxWorkspace) => Promise<void>): Promise<void> {
    this.workspaceError = '';
    try {
      const workspace = this.scopedWorkspace();
      await linuxRuntime.editWorkspace(() => change(workspace));
      await this.refreshWorkspace();
    } catch (error) { if (this.unsubscribe) { this.workspaceError = (error as Error).message; } }
  }

  private async pickFolder(): Promise<void> {
    if (this.locked() || this.picking || !this.folderSupported) { return; }
    this.picking = true;
    this.workspaceError = '';
    const id = this.workspaceId;
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;
      const uris = await new picker.DocumentViewPicker(this.host()).select(options);
      if (this.unsubscribe && id === this.workspaceId && uris.length > 0) {
        await this.editWorkspace((workspace) => workspace.addMount(uris[0].replace(/\/+$/, '')));
      }
    } catch (error) { if (this.unsubscribe) { this.workspaceError = (error as Error).message; } }
    finally { if (this.unsubscribe) { this.picking = false; } }
  }

  private confirmClear(): void {
    const id = this.workspaceId;
    this.getUIContext().showAlertDialog({
      systemMaterial: this.appearance.surface, title: t('清空 Linux 项目目录？'),
      message: t('此操作将删除此项目保存的 Linux 文件。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('清空'), fontColor: $r('app.color.danger'), action: () => {
        if (this.workspaceId === id) { this.editWorkspace((workspace) => workspace.clearProject()); }
      } }
    });
  }

  private status(): string {
    if (!this.runtime.available) { return t('当前安装包未包含 Linux 运行时'); }
    if (!this.runtime.ready) { return t('无法读取 Linux 沙盒配置。'); }
    if (this.runtime.stopping) { return t('正在停止任务'); }
    if (this.runtime.active === 'warm-up') { return t('正在预热'); }
    if (this.runtime.active === 'self-test') { return t('正在运行自检'); }
    if (this.runtime.active === 'console') { return t('Linux 控制台'); }
    if (this.runtime.active) { return t('运行中'); }
    if (this.runtime.fault) { return t('需要重启应用'); }
    if (!this.runtime.settings.enabled) { return t('已停用'); }
    if (this.runtime.memoryInUse !== undefined) { return t('引擎已就绪'); }
    if (this.runtime.assetsReady) { return t('镜像已就绪'); }
    return t('待命');
  }

  private jobLabel(job: LinuxJobStatus): string {
    const outcome = job.outcome === 'complete' ? t('已完成') : job.outcome === 'cancelled' ? t('已停止') : t('失败');
    const label = job.kind === 'self-test' ? t('运行自检') : job.kind === 'warm-up' ? t('预热') :
      job.kind === 'console' ? t('Linux 控制台') : t('沙盒任务');
    return label + ' · ' + outcome + ' · ' + t('{0} 秒', [(job.elapsedMs / 1000).toFixed(1)]);
  }

  private locked(): boolean { return !this.runtime.ready || this.runtime.saving || this.runtime.active !== undefined; }

  private async save(update: LinuxRuntimeSettingsUpdate): Promise<void> {
    this.error = '';
    try { await linuxRuntime.save(update); }
    catch (error) { if (this.unsubscribe) { this.error = (error as Error).message; } }
  }

  private pickMemory(index: number): void {
    if (index === LINUX_MEMORY.length) {
      this.memoryDraft = String(this.runtime.settings.memoryMiB);
      this.editingMemory = true;
      return;
    }
    this.editingMemory = false;
    this.save({ memoryMiB: LINUX_MEMORY[index] });
  }

  private memoryProfile(): number {
    const preset = LINUX_MEMORY.indexOf(this.runtime.settings.memoryMiB);
    return this.editingMemory || preset < 0 ? LINUX_MEMORY.length : preset;
  }

  private applyCustomMemory(): void {
    if (this.locked() || !this.runtime.settings.enabled || !this.memoryDraft.trim()) { return; }
    this.save({ memoryMiB: Number(this.memoryDraft) });
  }

  private async selfTest(warmUp: boolean = false): Promise<void> {
    this.error = '';
    try { await linuxRuntime.selfTest(this.host(), warmUp); }
    catch (error) {
      if (this.unsubscribe && !(error instanceof RunCancelledError)) { this.error = (error as Error).message; }
    }
  }

  build() {
    Scroll() {
      Column({ space: Space.md }) {
        GroupCard() {
          Column({ space: Space.sm }) {
            Text(t('Linux 运行时')).fontFamily(this.appearance.fontFamily).fontSize(Font.title)
              .fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Medium)
            Text(this.status()).id('linux-runtime-status').fontFamily(this.appearance.fontFamily)
              .fontSize(Font.body).fontColor($r('app.color.text_primary'))
            if (this.runtime.available) {
              Text(t('Alpine Linux · ARM64 · 离线')).fontFamily(this.appearance.fontFamily)
                .fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              Text((this.runtime.separateProcess ? t('独立进程') : t('应用内虚拟机')) + ' · 1 vCPU · ' +
                (this.runtime.memoryInUse ?? this.runtime.settings.memoryMiB) + ' MiB')
                .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              if (this.assetBytes > 0) {
                Text(t('内核与镜像 {0} MiB', [(this.assetBytes / 1048576).toFixed(1)])).fontFamily(this.appearance.fontFamily)
                  .fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              }
              if (this.runtime.active) {
                Button(t('停止当前任务')).id('linux-runtime-stop').fontFamily(this.appearance.fontFamily)
                  .attributeModifier(Btn.tonal).enabled(!this.runtime.stopping).onClick(() => linuxRuntime.stop())
              } else {
                Row({ space: Space.sm }) {
                  Button(t('手动预热')).id('linux-runtime-warm-up').fontFamily(this.appearance.fontFamily)
                    .attributeModifier(Btn.tonal)
                    .enabled(!this.locked() && this.runtime.settings.enabled && !this.runtime.fault)
                    .onClick(() => this.selfTest(true))
                  Button(t('运行自检')).id('linux-runtime-self-test').fontFamily(this.appearance.fontFamily)
                    .attributeModifier(Btn.tonal)
                    .enabled(!this.locked() && this.runtime.settings.enabled && !this.runtime.fault)
                    .onClick(() => this.selfTest())
                }
              }
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
        }
        if (this.error || this.runtime.settingsError || this.runtime.fault) {
          Banner({ text: this.error || this.runtime.settingsError || this.runtime.fault,
            compId: 'linux-runtime-error' })
        }
        if (this.runtime.available) {
          GroupCard() {
            Column() {
              SwitchRow({ title: t('启用 Linux 沙盒'), isOn: this.runtime.ready && this.runtime.settings.enabled,
                disabled: this.locked(), compId: 'linux-runtime-enabled',
                onChange: (value: boolean) => this.save({ enabled: value }) })
              RowDivider()
              SwitchRow({ title: t('打开应用后预热'), isOn: this.runtime.settings.startup === 'prewarm',
                disabled: this.locked() || !this.runtime.settings.enabled, compId: 'linux-runtime-startup',
                onChange: (value: boolean) => this.save({ startup: value ? 'prewarm' : 'on-demand' }) })
              RowDivider()
              SwitchRow({ title: t('允许从工作区导入文件'), isOn: this.runtime.ready && this.runtime.settings.allowInput,
                disabled: this.locked() || !this.runtime.settings.enabled, compId: 'linux-runtime-import',
                onChange: (value: boolean) => this.save({ allowInput: value }) })
              RowDivider()
              SwitchRow({ title: t('允许向工作区导出文件'), isOn: this.runtime.ready && this.runtime.settings.allowOutput,
                disabled: this.locked() || !this.runtime.settings.enabled, compId: 'linux-runtime-export',
                onChange: (value: boolean) => this.save({ allowOutput: value }) })
              RowDivider()
              Column({ space: Space.sm }) {
                Text(t('任务超时')).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary'))
                Segmented({ options: LINUX_TIMEOUTS.map((seconds: number) => t('{0} 秒', [seconds])),
                  selected: LINUX_TIMEOUTS.indexOf(this.runtime.settings.timeoutSeconds), compIdPrefix: 'linux-runtime-timeout',
                  onSelect: (index: number) => this.save({ timeoutSeconds: LINUX_TIMEOUTS[index] }) })
                  .width('100%').enabled(!this.locked() && this.runtime.settings.enabled)
              }.id('linux-runtime-timeout').width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
              RowDivider()
              Column({ space: Space.sm }) {
                Text(t('虚拟机内存')).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary'))
                Segmented({ options: LINUX_MEMORY.map((memory: number) => memory + ' MiB').concat(t('自定义')),
                  selected: this.memoryProfile(), compIdPrefix: 'linux-runtime-memory',
                  onSelect: (index: number) => this.pickMemory(index) })
                  .width('100%').enabled(!this.locked() && this.runtime.settings.enabled)
                if (this.memoryProfile() === LINUX_MEMORY.length) {
                  Row({ space: Space.sm }) {
                    TextInput({ text: this.editingMemory ? this.memoryDraft : String(this.runtime.settings.memoryMiB), placeholder: 'MiB' })
                      .id('linux-runtime-custom-memory').fontFamily(this.appearance.fontFamily).attributeModifier(Styles.input)
                      .type(InputType.Number).layoutWeight(1).accessibilityText(t('虚拟机内存（MiB）'))
                      .maxLength(String(this.runtime.memoryLimit).length)
                      .enabled(!this.locked() && this.runtime.settings.enabled)
                      .onChange((value: string) => { this.editingMemory = true; this.memoryDraft = value; })
                      .onSubmit(() => this.applyCustomMemory())
                    Button(t('保存')).id('linux-runtime-save-memory').attributeModifier(Btn.tonal)
                      .enabled(!this.locked() && this.runtime.settings.enabled && this.editingMemory && this.memoryDraft.trim().length > 0)
                      .onClick(() => this.applyCustomMemory())
                  }.width('100%')
                }
                if (this.runtime.memoryInUse !== undefined && this.runtime.memoryInUse !== this.runtime.settings.memoryMiB) {
                  Text(t('内存设置将在应用重启后生效。')).fontFamily(this.appearance.fontFamily)
                    .fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
                }
              }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
            }
          }
          if (this.readOnly && this.runtime.settings.enabled) {
            Banner({ text: t('只读模式已开启，助手无法调用 Linux 沙盒。'), danger: false, compId: 'linux-runtime-read-only' })
          }
          if (this.workspaceId) { this.directories() }
          if (this.runtime.history.length > 0) { this.history() }
        }
      }.width('100%').padding(Space.page).attributeModifier(PageStyles.form)
    }.width('100%').height('100%').align(Alignment.Top).backgroundColor($r('app.color.page_background'))
  }

  @Builder
  directories() {
    SectionHeader({ title: this.projectName || t('当前对话') })
    GroupCard() {
      Column() {
        if (this.projectName) {
          SwitchRow({ title: t('项目持久目录'), subtitle: this.workspace.persistent && (!this.runtime.settings.allowInput || !this.runtime.settings.allowOutput) ?
            t('启用工作区导入和导出后，任务才能使用项目持久目录。') : '/work/project',
            isOn: this.workspace.persistent, disabled: this.locked() || !this.scopeReady, compId: 'linux-project-persistent',
            onChange: (value: boolean) => this.editWorkspace((workspace) => workspace.setPersistent(value)) })
          if (this.workspace.storedBytes > 0) {
            Row({ space: Space.sm }) {
              Text(t('占用 {0}', [storageSize(this.workspace.storedBytes)]))
                .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).layoutWeight(1)
              Button(t('清空')).id('linux-project-clear').attributeModifier(Btn.textSmall)
                .enabled(!this.locked() && this.scopeReady).onClick(() => this.confirmClear())
            }.width('100%').padding({ left: Space.lg, right: Space.lg })
          }
          RowDivider()
        }
        Column({ space: Space.xs }) {
          Text(t('挂载本机目录')).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary'))
          Text(this.folderSupported ? t('每次任务读取只读目录快照') : t('当前设备不支持目录授权。'))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          Button(t('选择目录')).id('linux-mount-add').attributeModifier(Btn.tonal)
            .enabled(!this.locked() && this.scopeReady && this.folderSupported && !this.picking)
            .onClick(() => this.pickFolder())
        }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
        ForEach(this.workspace.mounts, (mount: SharedFolder) => {
          RowDivider()
          Row({ space: Space.sm }) {
            Text('/work/mounts/' + mount.name).fontFamily(this.appearance.fontFamily).fontSize(Font.body)
              .fontColor($r('app.color.text_primary')).layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
            Button(t('卸载')).id('linux-mount-remove-' + mount.id).attributeModifier(Btn.textSmall)
              .enabled(!this.locked() && !this.picking).onClick(() => this.editWorkspace((workspace) => workspace.removeMount(mount.id)))
          }.width('100%').padding({ left: Space.lg, right: Space.lg, top: Space.sm, bottom: Space.sm })
        }, (mount: SharedFolder) => mount.id)
      }
    }
    if (this.workspace.mounts.length > 0 && !this.runtime.settings.allowInput) {
      Banner({ text: t('启用工作区导入后，任务才能读取挂载的目录。'), danger: false })
    }
    if (this.workspaceError) { Banner({ text: this.workspaceError, compId: 'linux-workspace-error' }) }
  }

  @Builder
  history() {
    SectionHeader({ title: t('最近沙盒任务') })
    GroupCard() {
      Column() {
        ForEach(this.runtime.history, (job: LinuxJobStatus, index: number) => {
          if (index > 0) { RowDivider() }
          Column({ space: Space.xs }) {
            Text(this.jobLabel(job)).fontFamily(this.appearance.fontFamily).fontSize(Font.body)
              .fontColor($r('app.color.text_primary'))
            Text(new Date(job.startedAt).toLocaleString() + (job.bootMs === undefined ? '' :
              ' · ' + t('Linux 启动 {0} 秒', [(job.bootMs / 1000).toFixed(1)])))
              .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
            if (job.error) {
              Text(job.error).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.danger'))
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(Space.lg)
        }, (job: LinuxJobStatus) => job.startedAt + ':' + job.kind)
      }
    }
  }
}
