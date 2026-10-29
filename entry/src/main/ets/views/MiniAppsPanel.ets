import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Space, Radius, relativeTime } from '../common/Theme';
import { Banner, Segmented } from '../common/Widgets';
import { materialMenuContent } from '../common/MaterialMenu';
import { t } from '../model/I18n';
import { MiniAppEntry, MiniAppStorage, miniAppInCollection, miniAppCanRollback } from '../model/MiniApp';
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

@Component
export struct MiniAppsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onChat: () => void = () => {};
  @Prop @Watch('showPreviewPicker') addRequest: number = 0;
  @Prop @Watch('refreshPreviews') previewRevision: string = '';
  onAddAvailable: (available: boolean) => void = () => {};
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
  @State private now: number = Date.now();
  @State private error: string = '';
  @State private notice: string = '';
  @State private viewportHeight: number = 600;
  private store?: MiniApps;
  private storage?: MiniAppStorage;
  private renameEntry?: MiniAppEntry;
  private mounted: boolean = false;
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private apps(): MiniApps {
    if (!this.store) { this.store = new MiniApps(this.context().getApplicationContext().filesDir); }
    return this.store;
  }
  aboutToAppear(): void { this.mounted = true; this.refreshPreviews(); this.run(async () => { await this.reload(); }); }
  aboutToDisappear(): void { this.mounted = false; this.onAddAvailable(false); }
  private async reload(): Promise<void> {
    const entries = (await this.apps().list()).filter((entry) => miniAppInCollection(entry.app));
    if (!this.mounted) { return; }
    this.entries = entries; this.now = Date.now(); this.refreshPreviews();
  }
  private async run(action: () => Promise<void>, label: string = t('正在加载小程序…')): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.busyLabel = label; this.error = ''; this.updateAddAvailable();
    try { await action(); }
    catch (error) { if (this.mounted) { this.error = (error as Error).message; } Diagnostics.log('error', 'mini-app', 'action_failed', {}, error as Error); }
    finally { if (this.mounted) { this.busy = false; this.busyLabel = ''; this.updateAddAvailable(); } }
  }
  private owner(entry: MiniAppEntry): string {
    return this.app.threads.find((thread) => thread.id === entry.app.sourceThreadId)?.displayTitle ||
      this.app.projects.find((project) => project.workspaceId === entry.workspaceId)?.name ||
      this.app.threads.find((thread) => thread.id === entry.workspaceId)?.title || t('保留的工作区');
  }
  private metadata(entry: MiniAppEntry): string {
    const time = entry.app.lastOpenedAt ? t('使用于 {0}', [relativeTime(entry.app.lastOpenedAt, this.now)]) :
      t('更新于 {0}', [relativeTime(entry.app.updatedAt, this.now)]);
    return t('来源：{0}', [this.owner(entry)]) + ' · ' + time;
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
  private updateAddAvailable(): void {
    if (this.mounted) { this.onAddAvailable(!this.selected && !this.busy && this.availablePreviews.length > 0); }
  }
  private refreshPreviews(): void {
    if (!this.mounted) { return; }
    this.availablePreviews = this.previews().filter((preview) => this.previewPage(preview) !== undefined); this.updateAddAvailable();
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
    Column({ space: Space.sm }) {
      Text(this.displayTitle(entry)).fontFamily(this.appearance.fontFamily).fontSize(18).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (entry.app.description) {
        Text(entry.app.description).fontSize(14).fontColor($r('app.color.text_secondary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text(this.metadata(entry)).fontSize(12).fontColor($r('app.color.text_tertiary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: Space.md, right: 60, top: Space.md, bottom: Space.md })
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
        }.id('mini-app-menu-' + this.entryKey(entry)).width(40).height(40).margin({ top: 8, right: 8 })
          .backgroundColor(Color.Transparent).enabled(!this.busy).accessibilityText(t('更多操作') + ' · ' + entry.app.title)
          .bindMenu(this.entryMenu(entry), { systemMaterial: this.appearance.menu, mask: false })
      }.width('100%')
      if (entry.app.archived) {
        Row() {
          Button(t('恢复')).attributeModifier(Btn.tonalSmall).id('mini-app-restore-' + this.entryKey(entry)).enabled(!this.busy)
            .onClick(() => this.run(async () => { await this.restore(entry); }, t('正在恢复「{0}」…', [entry.app.title])))
          Blank()
        }.width('100%').padding({ left: Space.md, right: Space.md, bottom: Space.md })
      }
    }.width('100%').borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
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
          selected: this.removed ? 1 : 0, optionIds: ['mini-apps-active', 'mini-apps-removed'], controlHeight: 40,
          onSelect: (index: number) => { if (!this.busy) { this.removed = index === 1; this.now = Date.now(); } } })
          .margin({ left: Space.md, right: Space.md, top: Space.sm }).enabled(!this.busy)
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: Space.md }) {
            if (!this.entries.some((entry) => entry.app.archived === this.removed) && !this.busy) {
              ListItem() {
                Text(this.removed ? t('没有已移除的小程序。') : t('让 Tinybot 创建一个记账本或习惯记录器，保存后会显示在这里。'))
                  .fontColor($r('app.color.text_secondary')).padding(24).width('100%').textAlign(TextAlign.Center)
              }
            }
            ForEach(this.entries.filter((entry) => entry.app.archived === this.removed), (entry: MiniAppEntry) => {
              ListItem() { this.entryCard(entry) }
            }, (entry: MiniAppEntry) => this.entryKey(entry) + ':' + entry.app.title + ':' + entry.app.updatedAt + ':' + entry.app.lastOpenedAt + ':' + entry.app.archived)
          }.id('mini-app-list').width('100%').height('100%').padding(Space.md).edgeEffect(EdgeEffect.Spring)
        }.layoutWeight(1).width('100%').onRefreshing(async () => {
          try { await this.run(async () => { await this.reload(); }); } finally { this.refreshing = false; }
        })
      }
      Column().width(0).height(0).bindSheet($$this.renaming, this.renameEditor(), { title: { title: t('重命名') },
        height: 240, backgroundColor: $r('app.color.page_background'), keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY })
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
      .bindSheet($$this.adding, this.previewPicker(), { title: { title: t('从当前会话的预览添加') },
        detents: [SheetSize.LARGE], backgroundColor: $r('app.color.page_background') })
  }
}
