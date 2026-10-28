import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Space, Radius } from '../common/Theme';
import { t } from '../model/I18n';
import { MiniAppEntry, MiniAppStorage } from '../model/MiniApp';
import { MiniApps } from '../services/MiniApps';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { PublishedPreview, stepPreviews } from '../model/PublishedPreview';
import { UiCompiler, uiParts } from '../model/InteractiveUi';
import { parseWebUi } from '../model/WebUi';
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
  @State private entries: MiniAppEntry[] = [];
  @State private selected: MiniAppEntry | undefined = undefined;
  @State private removed: boolean = false;
  @State private adding: boolean = false;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private notice: string = '';
  @State private viewportHeight: number = 600;
  private store?: MiniApps;
  private storage?: MiniAppStorage;
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private apps(): MiniApps {
    if (!this.store) { this.store = new MiniApps(this.context().getApplicationContext().filesDir); }
    return this.store;
  }
  aboutToAppear(): void { this.run(async () => { await this.reload(); }); }
  private async reload(): Promise<void> { this.entries = await this.apps().list(); }
  private async run(action: () => Promise<void>): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.error = ''; this.notice = '';
    try { await action(); }
    catch (error) { this.error = (error as Error).message; Diagnostics.log('error', 'mini-app', 'action_failed', {}, error as Error); }
    finally { this.busy = false; }
  }
  private owner(entry: MiniAppEntry): string {
    return this.app.projects.find((project) => project.workspaceId === entry.workspaceId)?.name ||
      this.app.threads.find((thread) => thread.id === entry.workspaceId)?.title || t('保留的工作区');
  }
  private async open(entry: MiniAppEntry): Promise<void> {
    const repository = this.apps().repository(entry.workspaceId);
    await repository.load(entry.app.id);
    const app = await repository.change(entry.app.id, 'open');
    this.storage = repository.binding(app.id); this.selected = { workspaceId: entry.workspaceId, app: app };
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
          await this.reload();
        });
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
  private async savePreview(preview: PublishedPreview): Promise<void> {
    const nodes = uiParts(preview.content, false).filter((part) => part.kind === 'ui')
      .flatMap((part) => new UiCompiler().update(part.content, true).nodes).filter((node) => node.kind === 'web');
    if (nodes.length !== 1) { throw new Error(t('只能将单页面预览保存为小程序。')); }
    const id = this.apps().createId();
    await this.apps().repository(this.app.activeWorkspaceId).publish(id, preview.title, '', preview.path,
      this.app.active.id, parseWebUi(nodes[0].data || ''), false, new Cancellation());
    this.adding = false; this.removed = false; await this.reload();
    this.notice = t('已保存到小程序。预览中的临时数据不会自动迁移；如需保存账目等数据，可让 Tinybot 为它添加保存功能。');
  }
  @Builder
  entryCard(entry: MiniAppEntry) {
    Column({ space: Space.sm }) {
      Text(entry.app.title).fontFamily(this.appearance.fontFamily).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      if (entry.app.description) { Text(entry.app.description).fontSize(14).fontColor($r('app.color.text_secondary')) }
      Text(this.owner(entry)).fontSize(12).fontColor($r('app.color.text_tertiary'))
      Text(t('最近使用：{0}', [entry.app.lastOpenedAt ? new Date(entry.app.lastOpenedAt).toLocaleString() : t('尚未打开')])).fontSize(12).fontColor($r('app.color.text_tertiary'))
      Flex({ wrap: FlexWrap.Wrap }) {
        if (!entry.app.archived) {
          Button(t('打开')).attributeModifier(Btn.primary).id('mini-app-open-' + entry.app.id).margin(4)
            .onClick(() => this.run(async () => { await this.open(entry); }))
          Button(t('继续修改')).attributeModifier(Btn.textSmall).margin(4).enabled(!this.app.busy)
            .onClick(() => this.run(async () => { await this.edit(entry); }))
          if (entry.app.previousPage) {
            Button(t('恢复上一版页面')).attributeModifier(Btn.textSmall).margin(4)
              .onClick(() => this.run(async () => { await this.apps().repository(entry.workspaceId).change(entry.app.id, 'rollback'); await this.reload(); }))
          }
        } else {
          Button(t('恢复')).attributeModifier(Btn.tonal).margin(4)
            .onClick(() => this.run(async () => { await this.apps().repository(entry.workspaceId).change(entry.app.id, 'restore'); await this.reload(); }))
        }
        Button(t('导出')).attributeModifier(Btn.textSmall).margin(4).onClick(() => this.run(async () => { await this.exportApp(entry); }))
        Button(entry.app.archived ? t('永久删除') : t('移除')).attributeModifier(Btn.textSmall).margin(4).onClick(() => this.confirmRemove(entry))
      }.enabled(!this.busy)
    }.alignItems(HorizontalAlign.Start).padding(Space.md).width('100%').borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
  }
  build() {
    Column({ space: Space.sm }) {
      if (this.error) { Text(this.error).fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice).padding(Space.md) }
      if (this.notice) { Text(this.notice).fontColor($r('app.color.text_secondary')).padding(Space.md) }
      if (this.selected) {
        Row() {
          Button(t('返回列表')).attributeModifier(Btn.textSmall).onClick(() => this.back())
          Text(this.selected.app.title).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1).maxLines(1)
        }.width('100%')
        Column() {
          WebUiView({ content: JSON.stringify(this.selected.app.page), storage: this.storage, interactive: true, viewportHeight: this.viewportHeight })
        }.layoutWeight(1).width('100%').onAreaChange((_old: Area, next: Area) => { this.viewportHeight = Math.max(200, Number(next.height)); })
      } else {
        Row() {
          Button(this.removed ? t('查看使用中') : t('查看已移除')).attributeModifier(Btn.textSmall).onClick(() => { this.removed = !this.removed; })
          Blank()
          Button(t('刷新')).attributeModifier(Btn.textSmall).enabled(!this.busy).onClick(() => this.run(async () => { await this.reload(); }))
        }.width('100%')
        Scroll() {
          Column({ space: Space.md }) {
            Button(t('从当前会话的预览添加')).attributeModifier(Btn.tonal).width('100%').enabled(!this.busy && !this.app.busy)
              .onClick(() => { this.adding = !this.adding; })
            if (this.adding) {
              if (!this.previews().length) { Text(t('当前会话还没有可保存的页面预览。')).fontColor($r('app.color.text_secondary')) }
              ForEach(this.previews(), (preview: PublishedPreview) => {
                Button(preview.title).attributeModifier(Btn.tonal).width('100%').enabled(!this.busy)
                  .onClick(() => this.run(async () => { await this.savePreview(preview); }))
              }, (preview: PublishedPreview) => preview.id)
            }
            if (!this.entries.some((entry) => entry.app.archived === this.removed)) {
              Text(this.removed ? t('没有已移除的小程序。') : t('让 Tinybot 创建一个记账本或习惯记录器，保存后会显示在这里。'))
                .fontColor($r('app.color.text_secondary')).padding(24)
            }
            ForEach(this.entries.filter((entry) => entry.app.archived === this.removed), (entry: MiniAppEntry) => {
              this.entryCard(entry)
            }, (entry: MiniAppEntry) => entry.workspaceId + ':' + entry.app.id + ':' + entry.app.updatedAt + ':' + entry.app.lastOpenedAt + ':' + entry.app.archived)
          }.width('100%').padding(Space.md)
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
