import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Space, Radius, relativeTime } from '../common/Theme';
import { Banner, Segmented } from '../common/Widgets';
import { materialMenuContent } from '../common/MaterialMenu';
import { t } from '../model/I18n';
import { MiniAppEntry, MiniAppStorage, miniAppInCollection, miniAppCanRollback, MINI_APP_ICON_COLOR_IDS } from '../model/MiniApp';
import { MiniApps } from '../services/MiniApps';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { PublishedPreview, stepPreviews } from '../model/PublishedPreview';
import { UiCompiler, uiParts } from '../model/InteractiveUi';
import { WebUiSpec, parseWebUi } from '../model/WebUi';
import { Cancellation } from '../services/Cancellation';
import { exportFile } from '../services/NativeActions';
import { writeBytes } from '../services/Attachments';
import { Diagnostics } from '../model/Diagnostics';
import { WebUiView } from './WebUiView';

interface MiniAppIconChoice { id: string; name: string; symbol: Resource; }
interface MiniAppIconColorChoice { id: string; name: string; foreground: ResourceColor; background: ResourceColor; }

@Component
export struct MiniAppsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onChat: () => void = () => {};
  @Prop @Watch('createRequested') createRequest: number = 0;
  @Prop @Watch('refreshPreviews') previewRevision: string = '';
  onCreateAvailable: (available: boolean) => void = () => {};
  @State private entries: MiniAppEntry[] = [];
  @State private selected: MiniAppEntry | undefined = undefined;
  @State private removed: boolean = false;
  @State private adding: boolean = false;
  @State private busy: boolean = false;
  @State private busyLabel: string = '';
  @State private refreshing: boolean = false;
  @State private availablePreviews: PublishedPreview[] = [];
  @State private renaming: boolean = false;
  @State private renameTitle: string = '';
  @State private choosingIcon: boolean = false;
  @State private currentIcon: string = 'default';
  @State private currentIconColor: string = 'green';
  @State private now: number = Date.now();
  @State private error: string = '';
  @State private notice: string = '';
  @State private viewportHeight: number = 600;
  private store?: MiniApps;
  private storage?: MiniAppStorage;
  private renameEntry?: MiniAppEntry;
  private iconEntry?: MiniAppEntry;
  private mounted: boolean = false;
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private apps(): MiniApps {
    if (!this.store) { this.store = new MiniApps(this.context().getApplicationContext().filesDir); }
    return this.store;
  }
  aboutToAppear(): void { this.mounted = true; this.refreshPreviews(); this.run(async () => { await this.reload(); }); }
  aboutToDisappear(): void { this.mounted = false; this.onCreateAvailable(false); }
  private async reload(): Promise<void> {
    const entries = (await this.apps().list()).filter((entry) => miniAppInCollection(entry.app));
    if (!this.mounted) { return; }
    this.entries = entries; this.now = Date.now(); this.refreshPreviews();
  }
  private async run(action: () => Promise<void>, label: string = t('正在加载小程序…')): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.busyLabel = label; this.error = ''; this.updateCreateAvailable();
    try { await action(); }
    catch (error) { if (this.mounted) { this.error = (error as Error).message; } Diagnostics.log('error', 'mini-app', 'action_failed', {}, error as Error); }
    finally { if (this.mounted) { this.busy = false; this.busyLabel = ''; this.updateCreateAvailable(); } }
  }
  private owner(entry: MiniAppEntry): string {
    return this.app.threads.find((thread) => thread.id === entry.app.sourceThreadId)?.displayTitle ||
      this.app.projects.find((project) => project.workspaceId === entry.workspaceId)?.name ||
      this.app.threads.find((thread) => thread.id === entry.workspaceId)?.title || t('保留的工作区');
  }
  private metadata(entry: MiniAppEntry): string {
    return t('来源：{0}', [this.owner(entry)]) + ' · ' + this.usedAt(entry);
  }
  private usedAt(entry: MiniAppEntry): string {
    return entry.app.lastOpenedAt ? t('使用于 {0}', [relativeTime(entry.app.lastOpenedAt, this.now)]) :
      t('更新于 {0}', [relativeTime(entry.app.updatedAt, this.now)]);
  }
  // Missing color metadata preserves the original identity-based palette for existing apps.
  private entryIconColor(entry: MiniAppEntry): string {
    if (entry.app.iconColor !== undefined) { return entry.app.iconColor; }
    let hash = 0;
    const key = this.entryKey(entry);
    for (let index = 0; index < key.length; index++) { hash = (hash * 31 + key.charCodeAt(index)) | 0; }
    return MINI_APP_ICON_COLOR_IDS[(hash >>> 0) % MINI_APP_ICON_COLOR_IDS.length];
  }
  private iconColorChoices(): MiniAppIconColorChoice[] {
    return [
      { id: 'green', name: t('绿色'), foreground: $r('app.color.avatar_1_fg'), background: $r('app.color.avatar_1_bg') },
      { id: 'blue', name: t('蓝色'), foreground: $r('app.color.avatar_2_fg'), background: $r('app.color.avatar_2_bg') },
      { id: 'orange', name: t('橙色'), foreground: $r('app.color.avatar_3_fg'), background: $r('app.color.avatar_3_bg') },
      { id: 'purple', name: t('紫色'), foreground: $r('app.color.avatar_4_fg'), background: $r('app.color.avatar_4_bg') },
      { id: 'rose', name: t('粉色'), foreground: $r('app.color.avatar_5_fg'), background: $r('app.color.avatar_5_bg') }
    ];
  }
  private iconPalette(color: string): MiniAppIconColorChoice {
    const palette = this.iconColorChoices().find((choice) => choice.id === color);
    if (!palette) { throw new Error('Invalid mini app icon color: ' + color); }
    return palette;
  }
  private iconColor(entry: MiniAppEntry, background: boolean): ResourceColor {
    const palette = this.iconPalette(this.entryIconColor(entry));
    return background ? palette.background : palette.foreground;
  }
  private iconChoices(): MiniAppIconChoice[] {
    return [
      { id: 'default', name: t('默认'), symbol: $r('sys.symbol.rectangle_stack') },
      { id: 'document', name: t('文档'), symbol: $r('sys.symbol.doc_text') },
      { id: 'list', name: t('清单'), symbol: $r('sys.symbol.list_bullet') },
      { id: 'check', name: t('打卡'), symbol: $r('sys.symbol.checkmark_circle') },
      { id: 'clock', name: t('时间'), symbol: $r('sys.symbol.clock') },
      { id: 'folder', name: t('文件夹'), symbol: $r('sys.symbol.folder') },
      { id: 'idea', name: t('灵感'), symbol: $r('sys.symbol.lightbulb') },
      { id: 'star', name: t('星标'), symbol: $r('sys.symbol.star') },
      { id: 'people', name: t('成员'), symbol: $r('sys.symbol.person_2') },
      { id: 'note', name: t('笔记'), symbol: $r('sys.symbol.square_and_pencil') },
      { id: 'picture', name: t('图片'), symbol: $r('sys.symbol.picture') },
      { id: 'tools', name: t('工具'), symbol: $r('sys.symbol.wrench_and_screwdriver') },
      { id: 'voice', name: t('语音'), symbol: $r('sys.symbol.mic') },
      { id: 'audio', name: t('音频'), symbol: $r('sys.symbol.speaker_wave_2') },
      { id: 'link', name: t('链接'), symbol: $r('sys.symbol.link') },
      { id: 'message', name: t('消息'), symbol: $r('sys.symbol.ellipsis_message') }
    ];
  }
  private iconSymbol(icon: string = 'default'): Resource {
    const choice = this.iconChoices().find((choice) => choice.id === icon);
    if (!choice) { throw new Error('Invalid mini app icon: ' + icon); }
    return choice.symbol;
  }
  private changeIcon(entry: MiniAppEntry): void {
    this.iconEntry = entry; this.currentIcon = entry.app.icon ?? 'default'; this.currentIconColor = this.entryIconColor(entry);
    this.error = ''; this.choosingIcon = true;
  }
  private iconChanged(): boolean {
    return !!this.iconEntry && (this.currentIcon !== (this.iconEntry.app.icon ?? 'default') ||
      this.currentIconColor !== this.entryIconColor(this.iconEntry));
  }
  private async saveIcon(): Promise<void> {
    const entry = this.iconEntry;
    if (!entry) { return; }
    await this.apps().repository(entry.workspaceId).setIcon(entry.app.id, this.currentIcon, this.currentIconColor);
    this.choosingIcon = false; await this.reload(); this.success(t('已更换图标'));
  }
  private entryKey(entry: MiniAppEntry): string { return entry.workspaceId + ':' + entry.app.id; }
  private displayTitle(entry: MiniAppEntry): string {
    const matches = this.entries.filter((item) => item.app.title === entry.app.title)
      .sort((a, b) => a.app.createdAt - b.app.createdAt || this.entryKey(a).localeCompare(this.entryKey(b)));
    return matches.length > 1 ? t('{0}（{1}）', [entry.app.title,
      matches.findIndex((item) => this.entryKey(item) === this.entryKey(entry)) + 1]) : entry.app.title;
  }
  private count(removed: boolean): number { return this.entries.filter((entry) => entry.app.archived === removed).length; }
  private success(message: string): void {
    if (this.mounted) { this.getUIContext().getPromptAction().showToast({ message: message, systemMaterial: this.appearance.surface }); }
  }
  private rename(entry: MiniAppEntry): void {
    this.renameEntry = entry; this.renameTitle = entry.app.title; this.renaming = true;
  }
  private async saveName(): Promise<void> {
    const entry = this.renameEntry;
    if (!entry || !this.renameTitle.trim()) { return; }
    await this.apps().repository(entry.workspaceId).rename(entry.app.id, this.renameTitle);
    this.renaming = false; await this.reload(); this.success(t('已重命名'));
  }
  private async restore(entry: MiniAppEntry): Promise<void> {
    await this.apps().repository(entry.workspaceId).change(entry.app.id, 'restore');
    await this.reload(); this.success(t('已恢复小程序'));
  }
  private async open(entry: MiniAppEntry): Promise<void> {
    const repository = this.apps().repository(entry.workspaceId);
    await repository.load(entry.app.id);
    const app = await repository.change(entry.app.id, 'open');
    if (this.mounted) { this.storage = repository.binding(app.id); this.selected = { workspaceId: entry.workspaceId, app: app }; }
  }
  back(): boolean {
    if (this.selected) { this.selected = undefined; this.storage = undefined; this.run(async () => { await this.reload(); }); return true; }
    return false;
  }
  private confirmRemove(entry: MiniAppEntry): void {
    const permanent = entry.app.archived;
    this.getUIContext().showAlertDialog({ title: permanent ? t('永久删除小程序和数据') : t('移除小程序'),
      message: permanent ? t('将删除此小程序的页面和全部数据，无法撤销。请先导出备份。') : t('从列表移除后，数据仍会保留，可在已移除列表中恢复。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: permanent ? t('永久删除') : t('移除'), fontColor: $r('app.color.danger'), action: () => {
        this.run(async () => {
          if (permanent) { await this.apps().remove(entry.workspaceId, entry.app.id); }
          else { await this.apps().repository(entry.workspaceId).change(entry.app.id, 'archive'); }
          await this.reload(); this.success(permanent ? t('已永久删除') : t('已移除，可在已移除列表中恢复'));
        }, t('正在移除「{0}」…', [entry.app.title]));
      } } });
  }
  private async exportApp(entry: MiniAppEntry): Promise<void> {
    const repository = this.apps().repository(entry.workspaceId);
    const data = await repository.readData(entry.app.id), app = await repository.get(entry.app.id);
    const text = JSON.stringify({ format: 'tinybot-mini-app.v1', app: app, data: data.value }, null, 2);
    const path = this.context().cacheDir + '/mini-app-' + util.generateRandomUUID() + '.json';
    await writeBytes(path, new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer);
    try { await exportFile(this.context(), path, app.id + '.json'); }
    finally { await fs.unlink(path); }
  }
  private async edit(entry: MiniAppEntry): Promise<void> {
    const source = this.app.threads.find((thread) => thread.id === entry.app.sourceThreadId);
    if (!source || (source.projectId ? this.app.projects.find((project) => project.id === source.projectId)?.workspaceId : source.id) !== entry.workspaceId) {
      throw new Error(t('原会话已删除或已移至其他工作区。小程序仍可使用，请先导出后在新会话中继续修改。'));
    }
    if (!await this.app.selectThread(source.id)) { throw new Error(this.app.error || t('无法打开原会话。')); }
    const prompt = t('继续修改小程序「{0}」。先用 list_mini_apps 查看信息；更新时使用 appId="{1}"，保留现有用户数据。', [entry.app.title, entry.app.id]);
    this.app.setDraft(this.app.draft ? this.app.draft + '\n\n' + prompt : prompt); this.onChat();
  }
  private previews(): PublishedPreview[] {
    return this.app.active.messages.flatMap((message) => message.stepViews.flatMap((step, index) =>
      stepPreviews(message.id, step, index, this.app.active.latestPreviewIds, true))).filter((preview) => !preview.superseded);
  }
  private updateCreateAvailable(): void {
    if (this.mounted) { this.onCreateAvailable(!this.selected && !this.busy); }
  }
  private createRequested(): void {
    if (!this.mounted || this.busy || this.app.busy || this.selected || !this.app.ready) { return; }
    this.run(async () => {
      if (!await this.app.newThread()) { throw new Error(this.app.error || this.app.saveError || t('无法创建新对话。')); }
      this.app.setDraft(t('我想创建一个可以反复使用的小程序。请先和我确认用途，再开始制作。'));
      await this.app.flushDraft();
      if (this.mounted) { this.onChat(); }
    }, t('正在创建对话…'));
  }
  private refreshPreviews(): void {
    if (!this.mounted) { return; }
    this.availablePreviews = this.previews().filter((preview) => this.previewPage(preview) !== undefined); this.updateCreateAvailable();
  }
  private showPreviewPicker(): void {
    if (!this.mounted || this.busy || this.app.busy || this.selected) { return; }
    this.refreshPreviews(); this.adding = this.availablePreviews.length > 0;
  }
  private previewPage(preview: PublishedPreview): WebUiSpec | undefined {
    const nodes = uiParts(preview.content, false).filter((part) => part.kind === 'ui')
      .flatMap((part) => new UiCompiler().update(part.content, true).nodes).filter((node) => node.kind === 'web');
    return nodes.length === 1 ? parseWebUi(nodes[0].data || '') : undefined;
  }
  private async savePreview(preview: PublishedPreview): Promise<void> {
    const page = this.previewPage(preview);
    if (!page) { throw new Error(t('只能将单页面预览保存为小程序。')); }
    const id = this.apps().createId();
    await this.apps().repository(this.app.activeWorkspaceId).publish(id, preview.title, '', preview.path,
      this.app.active.id, page, false, new Cancellation());
    this.adding = false; this.removed = false; await this.reload();
    this.notice = t('已保存到小程序。预览中的临时数据不会自动迁移；如需保存账目等数据，可让 Tinybot 为它添加保存功能。');
  }
  @Builder
  entryMenu(entry: MiniAppEntry) {
    Menu() {
      if (!entry.app.archived) {
        MenuItem(() => materialMenuContent.bind(this)({ label: t('继续修改'), icon: $r('sys.symbol.square_and_pencil') }))
          .id('mini-app-edit-' + this.entryKey(entry)).enabled(!this.app.busy && !this.busy)
          .onClick(() => this.run(async () => { await this.edit(entry); }, t('正在打开原会话…')))
      }
      MenuItem(() => materialMenuContent.bind(this)({ label: t('重命名'), icon: $r('sys.symbol.square_and_pencil') }))
        .id('mini-app-rename-' + this.entryKey(entry)).enabled(!this.busy).onClick(() => this.rename(entry))
      MenuItem(() => materialMenuContent.bind(this)({ label: t('更换图标'), icon: $r('sys.symbol.rectangle_stack') }))
        .id('mini-app-change-icon-' + this.entryKey(entry)).enabled(!this.busy).onClick(() => this.changeIcon(entry))
      MenuItem(() => materialMenuContent.bind(this)({ label: t('导出'), icon: $r('sys.symbol.share') }))
        .id('mini-app-export-' + this.entryKey(entry)).enabled(!this.busy)
        .onClick(() => this.run(async () => { await this.exportApp(entry); }, t('正在导出「{0}」…', [entry.app.title])))
      if (!entry.app.archived && miniAppCanRollback(entry.app)) {
        MenuItem(() => materialMenuContent.bind(this)({ label: t('恢复上一版页面'), icon: $r('sys.symbol.arrow_counterclockwise') }))
          .id('mini-app-rollback-' + this.entryKey(entry)).enabled(!this.busy)
          .onClick(() => this.run(async () => {
            await this.apps().repository(entry.workspaceId).change(entry.app.id, 'rollback'); await this.reload();
            this.success(t('已恢复上一版页面'));
          }, t('正在恢复「{0}」…', [entry.app.title])))
      }
      MenuItem(() => materialMenuContent.bind(this)({ label: entry.app.archived ? t('永久删除') : t('移除'),
        icon: $r('sys.symbol.trash'), danger: true }))
        .id('mini-app-remove-' + this.entryKey(entry)).enabled(!this.busy).onClick(() => this.confirmRemove(entry))
    }.width(240)
  }
  @Builder
  cardContent(entry: MiniAppEntry) {
    Column({ space: Space.md }) {
      Row() {
        Stack() {
          SymbolGlyph(this.iconSymbol(entry.app.icon)).fontSize(24).fontColor([this.iconColor(entry, false)])
        }.width(44).height(44).borderRadius(Radius.md).backgroundColor(this.iconColor(entry, true))
          .accessibilityLevel('no-hide-descendants')
        Blank()
      }.width('100%').padding({ right: 40 })
      Column({ space: Space.xs }) {
        Text(this.displayTitle(entry)).fontFamily(this.appearance.fontFamily).fontSize(17).lineHeight(22).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(entry.app.description).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(18)
          .fontColor($r('app.color.text_secondary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ minHeight: 36 })
      }.width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: Space.sm }) {
        Text(t('来源：{0}', [this.owner(entry)])).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(16)
          .fontColor($r('app.color.text_tertiary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: Space.xs }) {
          SymbolGlyph($r('sys.symbol.clock')).fontSize(13).fontColor([$r('app.color.text_tertiary')])
            .accessibilityLevel('no-hide-descendants')
          Text(this.usedAt(entry)).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(16)
            .fontColor($r('app.color.text_tertiary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.SpaceBetween).width('100%').padding(Space.lg)
      .constraintSize({ minHeight: 216 })
  }
  @Builder
  entryCard(entry: MiniAppEntry) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (entry.app.archived) {
          this.cardContent(entry)
        } else {
          Button({ type: ButtonType.Normal }) { this.cardContent(entry) }
            .id('mini-app-open-' + this.entryKey(entry)).width('100%').padding(0).borderRadius(Radius.md)
            .backgroundColor(Color.Transparent).enabled(!this.busy)
            .accessibilityText(t('打开小程序「{0}」', [this.displayTitle(entry)]) + '，' + this.metadata(entry))
            .onClick(() => this.run(async () => { await this.open(entry); }, t('正在打开「{0}」…', [this.displayTitle(entry)])))
        }
        // A sibling of the open button: menu taps cannot bubble into opening the app.
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(20).fontColor([$r('app.color.text_secondary')])
        }.id('mini-app-menu-' + this.entryKey(entry)).width(44).height(44).margin({ top: 8, right: 4 })
          .backgroundColor(Color.Transparent).enabled(!this.busy).accessibilityText(t('更多操作') + ' · ' + entry.app.title)
          .bindMenu(this.entryMenu(entry), { systemMaterial: this.appearance.menu, mask: false })
      }.width('100%')
      if (entry.app.archived) {
        Row() {
          Button(t('恢复')).attributeModifier(Btn.tonal).layoutWeight(1).id('mini-app-restore-' + this.entryKey(entry)).enabled(!this.busy)
            .onClick(() => this.run(async () => { await this.restore(entry); }, t('正在恢复「{0}」…', [entry.app.title])))
        }.width('100%').padding({ left: Space.md, right: Space.md, bottom: Space.md })
      }
    }.width('100%').borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
      .border({ width: 0.5, color: $r('app.color.divider') })
  }
  @Builder
  feedback() {
    if (this.error) {
      Banner({ text: this.error, actionLabel: t('关闭'), compId: 'mini-app-error', actionId: 'mini-app-dismiss-error',
        onAction: () => { this.error = ''; } })
    }
    if (this.notice) {
      Banner({ text: this.notice, danger: false, actionLabel: t('关闭'), compId: 'mini-app-notice', actionId: 'mini-app-dismiss-notice',
        onAction: () => { this.notice = ''; } })
    }
    if (this.busy) {
      Row({ space: Space.sm }) {
        LoadingProgress().width(20).height(20).color(this.appearance.accent)
        Text(this.busyLabel).id('mini-app-progress').fontSize(13).fontColor($r('app.color.text_secondary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%').padding(Space.md)
    }
  }
  @Builder
  previewPicker() {
    Column({ space: Space.md }) {
      this.feedback()
      Text(t('添加后可从集合页重新打开。预览里的临时数据不会自动迁移。'))
        .fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
      List({ space: Space.sm }) {
        ForEach(this.availablePreviews, (preview: PublishedPreview) => {
          ListItem() {
            Button(preview.title).attributeModifier(Btn.tonal).width('100%').enabled(!this.busy && !this.app.busy)
              .onClick(() => this.run(async () => { await this.savePreview(preview); }, t('正在添加「{0}」…', [preview.title])))
          }
        }, (preview: PublishedPreview) => preview.id)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding(Space.md)
  }
  @Builder
  renameEditor() {
    Column({ space: Space.md }) {
      if (this.error) { Banner({ text: this.error, actionLabel: t('关闭'), onAction: () => { this.error = ''; } }) }
      TextInput({ text: this.renameTitle, placeholder: t('小程序名称') }).id('mini-app-name')
        .maxLength(160).enabled(!this.busy).onChange((value: string) => { this.renameTitle = value; })
      Row({ space: Space.sm }) {
        Button(t('取消')).attributeModifier(Btn.tonal).layoutWeight(1).enabled(!this.busy)
          .id('mini-app-name-cancel').onClick(() => { this.renaming = false; })
        Button(this.busy ? t('正在保存…') : t('保存')).attributeModifier(Btn.primary).layoutWeight(1)
          .id('mini-app-name-save').enabled(!this.busy && this.renameTitle.trim().length > 0)
          .onClick(() => this.run(async () => { await this.saveName(); }, t('正在保存…')))
      }.width('100%')
    }.width('100%').padding(Space.md)
  }
  @Builder
  iconPicker() {
    Column({ space: Space.lg }) {
      this.feedback()
      Row({ space: Space.md }) {
        Stack() {
          SymbolGlyph(this.iconSymbol(this.currentIcon)).fontSize(28)
            .fontColor([this.iconPalette(this.currentIconColor).foreground])
        }.id('mini-app-icon-preview').width(56).height(56).borderRadius(Radius.md)
          .backgroundColor(this.iconPalette(this.currentIconColor).background).accessibilityLevel('no-hide-descendants')
        Text(this.iconEntry ? this.displayTitle(this.iconEntry) : '').fontFamily(this.appearance.fontFamily)
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%')
      Scroll() {
        Column({ space: Space.md }) {
          Text(t('颜色')).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary')).width('100%')
          GridRow({ columns: 5, gutter: Space.sm }) {
            ForEach(this.iconColorChoices(), (color: MiniAppIconColorChoice) => {
              GridCol() {
                Button({ type: ButtonType.Normal }) {
                  Column({ space: Space.sm }) {
                    SymbolGlyph(this.iconSymbol(this.currentIcon)).fontSize(20).fontColor([color.foreground])
                    Text(color.name).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(16)
                      .fontColor(color.foreground).maxLines(2).textAlign(TextAlign.Center)
                  }.width('100%').padding({ left: Space.xs, right: Space.xs, top: Space.md, bottom: Space.md })
                }.id('mini-app-color-' + color.id).width('100%').padding(0).constraintSize({ minHeight: 72 }).borderRadius(Radius.md)
                  .backgroundColor(color.background).border({ width: 2, color: this.currentIconColor === color.id ? color.foreground : Color.Transparent })
                  .accessibilityText(color.name + (this.currentIconColor === color.id ? t('，已选中') : ''))
                  .enabled(!this.busy).onClick(() => { this.currentIconColor = color.id; })
              }
            }, (color: MiniAppIconColorChoice) => color.id)
          }.width('100%')
          Text(t('图标')).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary')).width('100%').margin({ top: Space.sm })
          GridRow({ columns: 4, gutter: { x: Space.sm, y: Space.sm } }) {
            ForEach(this.iconChoices(), (choice: MiniAppIconChoice) => {
              GridCol() {
                Button({ type: ButtonType.Normal }) {
                  Column({ space: Space.sm }) {
                    SymbolGlyph(choice.symbol).fontSize(26).fontColor([this.iconPalette(this.currentIconColor).foreground])
                    Text(choice.name).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(16)
                      .fontColor($r('app.color.text_primary')).maxLines(2).textAlign(TextAlign.Center)
                  }.width('100%').padding({ left: Space.xs, right: Space.xs, top: Space.md, bottom: Space.md })
                }.id('mini-app-icon-' + choice.id).width('100%').padding(0).constraintSize({ minHeight: 80 }).borderRadius(Radius.md)
                  .backgroundColor(this.currentIcon === choice.id ? this.iconPalette(this.currentIconColor).background : $r('app.color.surface'))
                  .border({ width: 1.5, color: this.currentIcon === choice.id ? this.iconPalette(this.currentIconColor).foreground : Color.Transparent })
                  .accessibilityText(choice.name + (this.currentIcon === choice.id ? t('，已选中') : ''))
                  .enabled(!this.busy).onClick(() => { this.currentIcon = choice.id; })
              }
            }, (choice: MiniAppIconChoice) => choice.id)
          }.width('100%')
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      Row({ space: Space.sm }) {
        Button(t('取消')).attributeModifier(Btn.tonal).layoutWeight(1).id('mini-app-icon-cancel').enabled(!this.busy)
          .onClick(() => { this.choosingIcon = false; })
        Button(this.busy ? t('正在保存…') : t('保存')).attributeModifier(Btn.primary).layoutWeight(1)
          .id('mini-app-icon-save').enabled(!this.busy && this.iconChanged())
          .onClick(() => this.run(async () => { await this.saveIcon(); }, t('正在保存…')))
      }.width('100%')
    }.width('100%').height('100%').padding(Space.lg)
  }
  @Builder
  collection() {
    Column({ space: Space.lg }) {
      if (!this.removed) {
        Text(t('你的工具，随时打开')).fontFamily(this.appearance.fontFamily).fontSize(14)
          .fontColor($r('app.color.text_secondary')).width('100%')
      }
      if (!this.entries.some((entry) => entry.app.archived === this.removed) && !this.busy) {
        Column({ space: Space.lg }) {
          SymbolGlyph($r('sys.symbol.rectangle_stack')).fontSize(36).fontColor([this.appearance.accent])
            .accessibilityLevel('no-hide-descendants')
          Text(this.removed ? t('没有已移除的小程序。') : t('让 Tinybot 创建一个记账本或习惯记录器，保存后会显示在这里。'))
            .fontFamily(this.appearance.fontFamily).fontSize(15).lineHeight(22).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Center)
          if (!this.removed) {
            Button(t('创建小程序')).attributeModifier(Btn.primary).id('mini-app-create-empty')
              .enabled(this.app.ready && !this.app.busy && !this.busy).onClick(() => this.createRequested())
          }
        }.width('100%').padding({ left: Space.lg, right: Space.lg, top: 48, bottom: 48 })
      }
      GridRow({ columns: { xs: 1, sm: 2, md: 3, lg: 4 }, gutter: { x: Space.md, y: Space.md },
        breakpoints: { value: ['320vp', '600vp', '840vp'], reference: BreakpointsReference.ComponentSize } }) {
        ForEach(this.entries.filter((entry) => entry.app.archived === this.removed), (entry: MiniAppEntry) => {
          GridCol() { this.entryCard(entry) }
        }, (entry: MiniAppEntry) => this.entryKey(entry) + ':' + entry.app.title + ':' + entry.app.updatedAt + ':' + entry.app.lastOpenedAt + ':' + entry.app.archived + ':' + (entry.app.icon ?? 'default') + ':' + (entry.app.iconColor ?? 'auto'))
      }.id('mini-app-grid').width('100%')
      if (!this.removed && this.availablePreviews.length > 0) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: Space.sm }) {
            SymbolGlyph($r('sys.symbol.plus_circle')).fontSize(22).fontColor([this.appearance.accent])
            Text(t('从当前会话的预览添加')).fontFamily(this.appearance.fontFamily).fontSize(14)
              .fontWeight(FontWeight.Medium).fontColor(this.appearance.accent).maxLines(2)
          }.justifyContent(FlexAlign.Center).width('100%').padding(Space.md)
        }.id('mini-app-add-preview').width('100%').constraintSize({ minHeight: 48 }).borderRadius(Radius.md)
          .backgroundColor($r('app.color.surface_variant')).enabled(!this.busy && !this.app.busy)
          .onClick(() => this.showPreviewPicker())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
  }
  build() {
    Column({ space: Space.sm }) {
      this.feedback()
      if (this.selected) {
        Row() {
          Button(t('返回列表')).attributeModifier(Btn.textSmall).id('mini-app-back').onClick(() => this.back())
          Text(this.selected.app.title).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
        Column() {
          WebUiView({ content: JSON.stringify(this.selected.app.page), storage: this.storage, interactive: true, viewportHeight: this.viewportHeight })
        }.layoutWeight(1).width('100%').onAreaChange((_old: Area, next: Area) => { this.viewportHeight = Math.max(200, Number(next.height)); })
      } else {
        Segmented({ options: [t('使用中 ({0})', [this.count(false)]), t('已移除 ({0})', [this.count(true)])],
          selected: this.removed ? 1 : 0, optionIds: ['mini-apps-active', 'mini-apps-removed'], controlHeight: 48,
          onSelect: (index: number) => { if (!this.busy) { this.removed = index === 1; this.now = Date.now(); } } })
          .margin({ left: Space.page, right: Space.page, top: Space.sm }).enabled(!this.busy)
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() { this.collection() }
            .id('mini-app-list').width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }.layoutWeight(1).width('100%').onRefreshing(async () => {
          try { await this.run(async () => { await this.reload(); }); } finally { this.refreshing = false; }
        })
      }
      Column().width(0).height(0).bindSheet($$this.renaming, this.renameEditor(), { title: { title: t('重命名') },
        height: 240, backgroundColor: $r('app.color.page_background'), keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY })
      Column().width(0).height(0).bindSheet($$this.choosingIcon, this.iconPicker(), { title: { title: t('图标与颜色') },
        detents: [SheetSize.LARGE], backgroundColor: $r('app.color.page_background') })
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
      .bindSheet($$this.adding, this.previewPicker(), { title: { title: t('从当前会话的预览添加') },
        detents: [SheetSize.LARGE], backgroundColor: $r('app.color.page_background') })
  }
}
