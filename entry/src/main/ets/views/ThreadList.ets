import { materialMenuContent } from '../common/MaterialMenu';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { FrameCallback, SymbolGlyphModifier } from '@kit.ArkUI';
import { Diagnostics } from '../model/Diagnostics';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { MAX_PROJECT_SHARED_FOLDERS, SharedFolder, sharedFolderNameFromUri, uniqueSharedFolderName } from '../model/SharedFolders';
import { ProjectFolderAccess } from '../services/ProjectFolderAccess';
import { Btn, Font, Motion, Radius, Space, shortTime } from '../common/Theme';
import { Banner, IconButton, Segmented } from '../common/Widgets';

class ThreadSection {
  id: string;
  title: string;
  threads: ThreadViewModel[] = [];

  constructor(id: string, title: string) {
    this.id = id; this.title = title;
  }
}

@Component
struct ThreadRow {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop query: string = '';
  @Prop workbench: boolean = false;
  @Prop lastBranch: boolean = false;
  @Prop activePath: boolean = false;
  @Prop selecting: boolean = false;
  @Prop selected: boolean = false;
  @State private rowHeight: number = 64;
  @ObjectLink thread: ThreadViewModel;
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  onSelectionChanged: (selected: boolean) => void = () => {};
  @State private editing: boolean = false;
  @State private name: string = '';

  private locked(): boolean {
    return !this.app.canNavigate;
  }

  private active(): boolean {
    return this.app.active.id === this.thread.id;
  }
  private matchId(): string { return this.thread.messages.find((item) => item.content.toLocaleLowerCase().includes(this.query.trim().toLocaleLowerCase()))?.id || ''; }
  private snippet(): string {
    const content = this.thread.messages.find((item) => item.id === this.matchId())?.content || this.thread.title;
    const index = content.toLocaleLowerCase().indexOf(this.query.trim().toLocaleLowerCase());
    return content.slice(Math.max(0, index - 20), Math.max(0, index - 20) + 110);
  }

  @Builder
  actions() {
    Menu() {
      if (!this.selecting) {
        MenuItem(() => materialMenuContent({ label: t("重命名"), icon: $r('sys.symbol.square_and_pencil') }))
          .onClick(() => { this.name = this.thread.title; this.editing = true; })
        MenuItem(() => materialMenuContent({ label: this.thread.pinned ? t("取消置顶") : t("置顶"), icon: $r('sys.symbol.pin') }))
          .onClick(() => this.app.pinThread(this.thread.id))
        MenuItem(() => materialMenuContent({ label: this.thread.archived ? t("恢复对话") : t("归档"), icon: $r('sys.symbol.archivebox') }))
          .enabled(!this.app.runningThreadIds.includes(this.thread.id))
          .onClick(() => this.app.archiveThread(this.thread.id))
        MenuItem(() => materialMenuContent({ label: t("删除"), icon: $r('sys.symbol.trash'), danger: true }))
          .enabled(!this.app.runningThreadIds.includes(this.thread.id))
          .onClick(() => {
            this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface,
              title: t("删除这段对话？"), message: this.thread.title + t("\n会话工作区中的文件会保留。"),
              primaryButton: { value: t("取消"), action: () => {} },
              secondaryButton: { value: t("删除"), fontColor: $r('app.color.danger'),
                action: () => { this.app.deleteThread(this.thread.id); } }
            });
          })
      }
    }
  }

  @Builder
  renameEditor() {
    Row({ space: 4 }) {
      TextInput({ text: this.name, placeholder: t("对话名称") }).fontFamily(this.appearance.fontFamily).maxLength(80).layoutWeight(1).height(40)
        .fontSize(15).backgroundColor($r('app.color.surface')).defaultFocus(true)
        .onChange((value: string) => { this.name = value; })
        .onSubmit(async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.xmark'), label: t("取消"), diameter: 36, iconSize: 18,
        tint: $r('app.color.text_secondary'), onTap: () => { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.checkmark'), label: t("保存名称"), diameter: 36, iconSize: 18,
        tint: this.appearance.accent, disabled: this.locked(),
        onTap: async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } } })
    }.width('100%').padding({ left: Space.sm, right: 4, top: 6, bottom: 6 })
  }

  build() {
    Stack({ alignContent: Alignment.End }) {
    Column() {
      if (this.editing && !this.selecting) {
        this.renameEditor()
      } else {
        Row({ space: Space.sm }) {
          if (this.selecting) {
            Checkbox({ name: this.thread.id }).id('thread-select-' + this.thread.id).select(this.selected)
              .shape(CheckBoxShape.CIRCLE).selectedColor(this.appearance.accent).width(22).height(22)
              .enabled(!this.locked()).accessibilityText(this.thread.displayTitle)
              .onChange((value: boolean) => { if (!this.locked()) { this.onSelectionChanged(value); } })
          }
          Column({ space: 4 }) {
            Row({ space: 4 }) {
              if (this.app.runningThreadIds.includes(this.thread.id)) {
                LoadingProgress().width(14).height(14).color(this.appearance.accent).accessibilityText(t('正在执行'))
              }
              if (this.thread.pinned) {
                SymbolGlyph($r('sys.symbol.pin_fill')).fontSize(13).fontColor([this.appearance.accent])
              }
              Text(this.thread.displayTitle).fontFamily(this.appearance.fontFamily).fontSize(15).maxLines(1).layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontWeight(this.active() ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.workbench ? $r('app.color.text_primary') : this.active() ? this.appearance.onAccentContainer : $r('app.color.text_primary'))
              if (this.workbench) {
                Text(shortTime(this.thread.updatedAt)).fontSize(11).fontColor($r('app.color.text_tertiary')).maxLines(1)
              }
            }.width('100%')
            if (this.query.trim()) { Text(this.snippet()).fontFamily(this.appearance.fontFamily).fontSize(12).maxLines(2).fontColor(this.appearance.accent) }
            if (this.thread.parentThreadId) { Text('↳ ' + (this.app.threads.find((item) => item.id === this.thread.parentThreadId)?.title || t("原对话已删除"))).fontFamily(this.appearance.fontFamily).fontSize(11).maxLines(1).fontColor($r('app.color.text_secondary')) }
            Row({ space: 6 }) {
              Text(shortTime(this.thread.updatedAt)).fontFamily(this.appearance.fontFamily).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
              if (this.thread.draft.length > 0) {
                Text(t("草稿")).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.danger'))
              }
            }.visibility(this.workbench ? Visibility.None : Visibility.Visible)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (!this.selecting) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
            }.fontFamily(this.appearance.fontFamily).width(32).height(32).backgroundColor(Color.Transparent).accessibilityText(t("对话管理"))
            .enabled(!this.locked()).bindMenu(this.actions, {
              systemMaterial: this.appearance.menu, mask: false })
          }
        }
        .width('100%').padding({ left: this.workbench && !this.thread.parentThreadId ? 28 : Space.md, right: 4,
          top: this.workbench ? 8 : 10, bottom: this.workbench ? 8 : 10 }).constraintSize({ minHeight: 44 })
        .onClick(async () => {
          if (this.locked()) { return; }
          if (this.selecting) { this.onSelectionChanged(!this.selected); return; }
          if (this.query.trim() ? await this.app.openMessage(this.thread.id, this.matchId(), this.query.trim()) : await this.app.selectThread(this.thread.id)) { this.onSelected(); }
        })
        .bindContextMenu(this.actions, ResponseType.LongPress, {
          systemMaterial: this.appearance.menu, mask: false })
      }
    }
    .width(this.workbench && !this.thread.parentThreadId ? '100%' : 'calc(100% - 28vp)').borderRadius(this.workbench ? 10 : Radius.md)
    .backgroundColor((this.selecting ? this.selected : this.active()) ? $r('app.color.selection') : Color.Transparent)
    .opacity(this.locked() && !this.active() ? 0.6 : 1)
    .onAreaChange((_old: Area, area: Area) => { this.rowHeight = Number(area.height); })
    Shape() {
      Path().commands(`M12 0 V${this.lastBranch ? this.rowHeight / 2 - 8 : this.rowHeight} M12 ${this.rowHeight / 2 - 8} Q12 ${this.rowHeight / 2} 20 ${this.rowHeight / 2} H28`)
        .stroke($r('app.color.divider'))
      Path().commands(this.active() ? `M12 0 V${this.rowHeight / 2 - 8} Q12 ${this.rowHeight / 2} 20 ${this.rowHeight / 2} H28` : `M12 0 V${this.rowHeight}`)
        .stroke(this.appearance.accent).strokeDashArray([this.rowHeight + 28, this.rowHeight + 28])
        .strokeDashOffset(this.activePath ? 0 : this.rowHeight + 28)
        .animation({ duration: Motion.drawer, curve: Motion.standard })
    }.viewPort({ x: 0, y: 0, width: '28px', height: this.rowHeight + 'px' })
      .width(28).height(this.rowHeight).fill(Color.Transparent).strokeWidth('1.25px')
      .strokeLineCap(LineCapStyle.Round).position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .visibility(this.workbench && !this.thread.parentThreadId ? Visibility.None : Visibility.Visible)
    }.id('thread-row-' + this.thread.id).width('100%')
  }
}

// Project tree; presentation grouping never changes a thread's stored project membership.
class ThreadSearchFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(): void { this.action(); }
}

@Component
export struct ThreadList {
  @Prop @Watch('searchAvailabilityChanged') active: boolean = true;
  @StorageProp('tinybot.foreground') @Watch('searchAvailabilityChanged') private foreground: boolean = true;
  @Prop workbench: boolean = false;
  // The persistent workbench column can collapse itself into the rail; the overlay
  // drawer cannot, so it omits the control.
  @Prop collapseHistory: boolean = false;
  @Prop @Watch('searchRequested') searchRequest: number = 0;
  @State @Watch('searchVisibilityChanged') private searchOpen: boolean = false;
  private mounted: boolean = false;
  private focusRequest: number = 0;
  onCollapseHistory: () => void = () => {};
  onNewChat: () => void = () => {};
  onTools: () => void = () => {};
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  onSettings: () => void = () => {};
  onMiniApps: () => void = () => {};
  onFiles: () => void = () => {};
  @State private query: string = '';
  @State private archived: boolean = false;
  @State private selecting: boolean = false;
  @State private selectedIds: string[] = [];
  @State private visibleCounts: Record<string, number> = {};
  @State private collapsedProjects: string[] = [];
  @State private projectEditing: boolean = false;
  @State private projectId: string = '';
  @State private projectName: string = '';
  @State private projectInstructions: string = '';
  @State private projectFolders: SharedFolder[] = [];
  @State private projectFolderError: string = '';

  aboutToAppear(): void {
    this.mounted = true;
    if (this.searchRequest > 0) { this.searchRequested(); }
  }
  aboutToDisappear(): void { this.mounted = false; this.focusRequest++; }
  private searchAvailabilityChanged(): void { if (!this.active || !this.foreground) { this.focusRequest++; } }
  private searchVisibilityChanged(): void { if (!this.searchOpen) { this.focusRequest++; } }

  // The rail can mount the search field and request its focus in the same frame.
  private searchRequested(): void {
    this.searchOpen = true;
    const request = ++this.focusRequest;
    this.getUIContext().postFrameCallback(new ThreadSearchFrame(() => {
      if (request !== this.focusRequest || !this.mounted || !this.searchOpen || !this.active || !this.foreground || this.locked()) { return; }
      Diagnostics.log('debug', 'focus', 'search_requested', { request: request });
      this.getUIContext().getFocusController().requestFocus('search-threads');
    }));
  }

  private filtered(): ThreadViewModel[] {
    return this.app.filteredThreads(this.query, this.archived);
  }
  private locked(): boolean { return !this.app.canNavigate; }
  private endSelection(): void { this.selecting = false; this.selectedIds = []; }
  private selectThread(id: string, selected: boolean): void {
    if (this.locked()) { return; }
    this.selectedIds = this.selectedIds.filter((item) => item !== id);
    if (selected) { this.selectedIds = this.selectedIds.concat(id); }
  }
  private allSelected(): boolean {
    const threads = this.filtered();
    return threads.length > 0 && threads.every((thread) => this.selectedIds.includes(thread.id));
  }
  private selectAll(): void {
    if (this.locked()) { return; }
    this.selectedIds = this.allSelected() ? [] : this.filtered().map((thread) => thread.id);
  }
  private async archiveSelected(): Promise<void> {
    if (this.locked() || this.selectedIds.length === 0 || this.selectedIds.some((id) => this.app.runningThreadIds.includes(id))) { return; }
    if (await this.app.archiveThreads(this.selectedIds.slice(), !this.archived)) { this.endSelection(); }
  }
  private confirmDeleteSelected(): void {
    if (this.locked() || this.selectedIds.length === 0 || this.selectedIds.some((id) => this.app.runningThreadIds.includes(id))) { return; }
    const ids = this.selectedIds.slice();
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface,
      title: t('删除选中的 {0} 段对话？', [ids.length]),
      message: t('删除后无法恢复。会话工作区中的文件会保留。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('删除'), fontColor: $r('app.color.danger'),
        action: async () => { if (await this.app.deleteThreads(ids)) { this.endSelection(); } } }
    });
  }
  private groupOpen(id: string): boolean { return !!this.query.trim() || !this.collapsedProjects.includes(id); }
  private visibleCount(id: string): number { return this.visibleCounts[id] || 20; }
  private onActivePath(id: string, threadId: string): boolean {
    const threads = this.sectionThreads(id);
    const index = threads.findIndex((item) => item.id === threadId);
    const activeIndex = threads.findIndex((item) => item.id === this.app.active.id);
    return index >= 0 && activeIndex >= index && activeIndex < this.visibleCount(id);
  }
  private lastBranch(id: string, threadId: string): boolean {
    const threads = this.sectionThreads(id);
    return threads[Math.min(threads.length, this.visibleCount(id)) - 1]?.id === threadId;
  }
  private sectionThreads(id: string): ThreadViewModel[] {
    const projectIds = new Set(this.app.projects.map((project) => project.id));
    return this.filtered().filter((thread) => (projectIds.has(thread.projectId || '') ? thread.projectId : '') === id);
  }
  private sectionTitle(id: string): string {
    return this.app.projects.find((project) => project.id === id)?.name || t('普通聊天');
  }
  private loadMore(id: string): void {
    const next: Record<string, number> = {};
    for (const key of Object.keys(this.visibleCounts)) { next[key] = this.visibleCounts[key]; }
    next[id] = this.visibleCount(id) + 20;
    this.visibleCounts = next;
  }
  private toggleGroup(id: string): void {
    this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard }, () => {
      this.collapsedProjects = this.collapsedProjects.includes(id) ? this.collapsedProjects.filter((item) => item !== id) : this.collapsedProjects.concat(id);
    });
  }
  private editProject(id: string = ''): void {
    const project = this.app.projects.find((item) => item.id === id);
    this.projectId = id; this.projectName = project?.name || ''; this.projectInstructions = project?.instructions || '';
    this.projectFolders = (project?.sharedFolders || []).slice(); this.projectFolderError = '';
    this.projectEditing = true;
  }
  private async addProjectFolders(): Promise<void> {
    if (this.locked()) { return; }
    if (this.projectFolders.length >= MAX_PROJECT_SHARED_FOLDERS) {
      this.projectFolderError = t('每个项目最多添加 {0} 个共享文件夹。', [MAX_PROJECT_SHARED_FOLDERS]); return;
    }
    if (!ProjectFolderAccess.canSelectFolders() || !ProjectFolderAccess.supported()) {
      this.projectFolderError = t('当前设备不支持项目共享文件夹。'); return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;
      const uris = await new picker.DocumentViewPicker(context).select(options);
      let next = this.projectFolders.slice();
      for (const uri of uris) {
        if (!uri.startsWith('file://') || next.some((item: SharedFolder) => item.uri === uri)) { continue; }
        const base = sharedFolderNameFromUri(uri);
        next = next.concat({ id: util.generateRandomUUID(), name: uniqueSharedFolderName(base, next),
          uri: uri.replace(/\/+$/, ''), addedAt: Date.now() });
      }
      this.projectFolders = next; this.projectFolderError = '';
    } catch (error) {
      this.projectFolderError = t('无法选择文件夹：') + (error as Error).message;
    }
  }
  private removeProjectFolder(id: string): void {
    this.projectFolders = this.projectFolders.filter((item: SharedFolder) => item.id !== id);
  }

  @Builder
  projectFolderRow(folder: SharedFolder) {
    Row({ space: Space.sm }) {
      SymbolGlyph($r('sys.symbol.folder')).fontSize(18).fontColor([this.appearance.accent])
      Column({ space: 2 }) {
        Text(folder.name).fontFamily(this.appearance.fontFamily).fontSize(14).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Text(t('项目内可读写')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button(t('移除')).fontFamily(this.appearance.fontFamily).id('project-remove-folder-' + folder.id)
        .attributeModifier(Btn.textSmall).enabled(!this.locked()).onClick(() => this.removeProjectFolder(folder.id))
    }.width('100%').padding({ left: Space.sm, right: Space.sm, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.surface_variant')).borderRadius(Radius.sm)
  }

  @Builder
  projectEditor() {
    Scroll() {
      Column({ space: Space.md }) {
        TextInput({ text: this.projectName, placeholder: t('项目名称') }).fontFamily(this.appearance.fontFamily).id('project-name').maxLength(80)
          .onChange((value: string) => { this.projectName = value; })
        TextArea({ text: this.projectInstructions, placeholder: t('项目说明与约定（可选）') }).fontFamily(this.appearance.fontFamily).id('project-instructions')
          .height(220).maxLength(16000).onChange((value: string) => { this.projectInstructions = value; })
        Row({ space: Space.sm }) {
          Text(t('共享文件夹')).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontWeight(FontWeight.Medium)
            .layoutWeight(1).fontColor($r('app.color.text_primary'))
          Button(t('添加文件夹')).fontFamily(this.appearance.fontFamily).id('project-add-folder')
            .attributeModifier(Btn.textSmall).enabled(!this.locked() && this.projectFolders.length < MAX_PROJECT_SHARED_FOLDERS)
            .onClick(() => this.addProjectFolders())
        }.width('100%')
        ForEach(this.projectFolders, (folder: SharedFolder) => { this.projectFolderRow(folder) },
          (folder: SharedFolder) => folder.id)
        Text(t('项目内的会话可以读写这些文件夹。')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
        if (this.projectFolderError.length > 0) { Banner({ text: this.projectFolderError }) }
        Text(t('项目内的会话共享文件和项目说明，各自保留对话历史。')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
        if (this.app.error) { Banner({ text: this.app.error }) }
        Button(t('保存')).fontFamily(this.appearance.fontFamily).id('project-save').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.sharedBusy && !this.app.saveError && this.projectName.trim().length > 0)
          .onClick(async () => {
            const creating = !this.projectId;
            if (await this.app.saveProject(this.projectName, this.projectInstructions, this.projectId || undefined, this.projectFolders)) {
              const id = this.projectId || this.app.active.projectId || '';
              // A newly created project must be visible even when launched from search or archives.
              if (creating) { this.query = ''; this.archived = false; this.visibleCounts = {}; }
              this.collapsedProjects = this.collapsedProjects.filter((item) => item !== id);
              this.projectEditing = false;
            }
          })
      }.width('100%').padding(Space.lg)
    }.width('100%').height('100%').align(Alignment.TopStart)
  }


  private sections(threads: ThreadViewModel[]): ThreadSection[] {
    const result = this.app.projects.map((project) => new ThreadSection(project.id, project.name));
    const ordinary = new ThreadSection('', t('普通聊天'));
    result.push(ordinary);
    for (const thread of threads) {
      const section = result.find((item: ThreadSection) => item.id === (thread.projectId || '')) || ordinary;
      section.threads.push(thread);
    }
    return this.query.trim() || this.archived ? result.filter((section) => section.threads.length > 0) : result;
  }

  @Builder
  projectActions(id: string) {
    Menu() {
      MenuItem(() => materialMenuContent({ label: t('项目文件'), icon: $r('sys.symbol.folder') }))
        .onClick(async () => { if (await this.app.openProject(id)) { this.onFiles(); } })
      MenuItem(() => materialMenuContent({ label: t('编辑项目'), icon: $r('sys.symbol.square_and_pencil') }))
        .onClick(() => this.editProject(id))
    }
  }

  @Builder
  workbenchMenu() {
    Menu() {
      MenuItem({ content: this.archived ? t('对话') : t('已归档'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.archivebox')) }).id('workbench-archive-toggle')
        .onClick(() => { this.archived = !this.archived; this.visibleCounts = {}; this.selectedIds = []; })
      MenuItem({ content: this.selecting ? t('取消') : t('多选'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.checkmark_circle')) }).id('workbench-selection-toggle')
        .onClick(() => { if (this.selecting) { this.endSelection(); } else { this.selecting = true; } })
    }
  }

  @Builder
  workbenchNavigation() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Blank().layoutWeight(1)
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(19).fontColor([$r('app.color.text_primary')])
        Text(t('新建对话')).fontSize(15).fontColor($r('app.color.text_primary'))
        Blank().layoutWeight(1)
      }.width('100%')
    }.id('workbench-new-chat').width('100%').height(44).padding({ left: 14, right: 14 }).borderRadius(12)
      .backgroundColor($r('app.color.page_background')).border({ width: 0.5, color: $r('app.color.divider'), radius: 12 })
      .enabled(!this.locked()).onClick(this.onNewChat)
    Column({ space: 2 }) {
      Button() {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(19).fontColor([$r('app.color.text_secondary')])
          Text(t('工作区文件')).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1).textAlign(TextAlign.Start)
        }.width('100%')
      }.id('workbench-sidebar-files').width('100%').height(44).padding({ left: 12, right: 12 })
        .borderRadius(10).backgroundColor(Color.Transparent).onClick(this.onFiles)
      Button() {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.wrench_and_screwdriver')).fontSize(19).fontColor([$r('app.color.text_secondary')])
          Text(t('记忆与工具')).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1).textAlign(TextAlign.Start)
        }.width('100%')
      }.id('workbench-sidebar-tools').width('100%').height(44).padding({ left: 12, right: 12 })
        .borderRadius(10).backgroundColor(Color.Transparent).onClick(this.onTools)
    }.width('100%').padding({ top: 8, bottom: 12 })
    Row({ space: 0 }) {
      Text(this.archived ? t('已归档') : t('工作区')).fontSize(13).fontColor($r('app.color.text_tertiary')).layoutWeight(1)
      IconButton({ icon: $r('sys.symbol.magnifyingglass'), label: t('搜索对话'), compId: 'workbench-search',
        diameter: 36, iconSize: 17, onTap: () => { this.searchOpen = !this.searchOpen; } })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(17).fontColor([$r('app.color.text_secondary')])
      }.id('workbench-history-options').width(36).height(36).backgroundColor(Color.Transparent)
        .accessibilityText(t('对话管理')).enabled(!this.locked()).bindMenu(this.workbenchMenu)
      IconButton({ icon: $r('sys.symbol.folder_badge_plus'), label: t('新建项目'), compId: 'workbench-project-create',
        diameter: 36, iconSize: 18, disabled: this.locked(), onTap: () => this.editProject() })
    }.width('100%').height(36).padding({ left: 4 })
  }

  @Builder
  sectionHeader(id: string) {
    Row({ space: 2 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 7 }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph(this.workbench ? $r('sys.symbol.folder') : $r('sys.symbol.chevron_down')).fontSize(this.workbench ? 18 : 12)
              .fontColor([$r('app.color.text_tertiary')])
          }.width(24).height(24)
            .rotate({ angle: this.workbench || this.groupOpen(id) ? 0 : -90, centerX: '50%', centerY: '50%' })
            .animation({ duration: Motion.medium, curve: Motion.standard })
          Text(this.sectionTitle(id)).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium).maxLines(1).layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor((this.app.active.projectId || '') === id ? this.appearance.accent : $r('app.color.text_secondary'))
          Text(String(this.sectionThreads(id).length)).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
            .visibility(this.workbench ? Visibility.None : Visibility.Visible)
        }.width('100%')
      }.fontFamily(this.appearance.fontFamily).id('project-group-' + (id || 'ordinary')).layoutWeight(1).height(44).padding({ right: 4 })
        .backgroundColor(Color.Transparent).borderRadius(10).onClick(() => this.toggleGroup(id))
        .accessibilityText(this.sectionTitle(id) + '，' + (this.groupOpen(id) ? t('收起') : t('展开')))
      if (!this.selecting) {
        IconButton({ icon: $r('sys.symbol.plus'), label: t('新对话') + ' · ' + this.sectionTitle(id),
          compId: 'project-new-chat-' + (id || 'ordinary'), diameter: 32, iconSize: 16,
          disabled: !this.app.canNavigate,
          onTap: async () => { if (await this.app.newThread(id)) { this.onSelected(); } } })
        if (id) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.fontFamily(this.appearance.fontFamily).id('project-actions-' + id).width(32).height(32).backgroundColor(Color.Transparent)
            .accessibilityText(t('编辑项目') + ' · ' + this.sectionTitle(id)).enabled(!this.app.sharedBusy && !this.app.saveError)
            .bindMenu(this.projectActions(id), { systemMaterial: this.appearance.menu, mask: false })
        }
      }
    }.width('100%').padding({ top: 4 }).backgroundColor($r('app.color.page_background'))
  }

  build() {
    Column() {
      if (this.active) { this.listContent() }
    }.width('100%').height('100%')
  }

  @Builder
  listContent() {
    Column({ space: Space.md }) {
      Row({ space: Space.sm }) {
        Image($r('app.media.tinybot')).width(28).height(28)
        Text('Tinybot').fontFamily(this.appearance.fontFamily).fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1).fontColor($r('app.color.text_primary'))
        if (!this.workbench) {
        Button(this.selecting ? t('取消') : t('多选')).fontFamily(this.appearance.fontFamily).id('thread-selection-mode').attributeModifier(Btn.textSmall)
          .enabled(!this.locked() && (this.selecting || this.filtered().length > 0))
          .onClick(() => { if (this.selecting) { this.endSelection(); } else { this.selecting = true; } })
        if (!this.selecting) {
          IconButton({ icon: $r('sys.symbol.folder_badge_plus'), label: t('新建项目'), compId: 'project-create',
            disabled: this.app.sharedBusy || !!this.app.saveError, onTap: () => this.editProject() })
        }
        } else if (this.collapseHistory) {
          // Desktop parity: the panel toggle lives in the sidebar's logo row.
          IconButton({ icon: $r('sys.symbol.line_3_horizontal'), label: t('收起会话栏'), compId: 'workbench-collapse-history',
            diameter: 36, iconSize: 18, onTap: this.onCollapseHistory })
        }
      }.width('100%').height(48).padding({ left: 4 })
      if (this.workbench) { this.workbenchNavigation() }
      Search({ value: this.query, placeholder: t("搜索对话") }).textFont({ family: this.appearance.fontFamily })
        .placeholderFont({ family: this.appearance.fontFamily }).id('search-threads').height(40)
        .backgroundColor($r('app.color.surface_variant')).placeholderColor($r('app.color.text_tertiary'))
        .enabled(!this.locked())
        .onChange((value: string) => { this.query = value; this.visibleCounts = {}; this.selectedIds = []; })
        .visibility(!this.workbench || this.searchOpen || this.query.length > 0 ? Visibility.Visible : Visibility.None)
      if (!this.workbench) {
      Segmented({ options: [t("对话"), t("已归档")], selected: this.archived ? 1 : 0,
        optionIds: ['active-threads', 'archived-threads'], controlHeight: 38, labelSize: 13,
        trackRadius: 19, thumbRadius: 16, gap: 2, thumbShadow: false,
        onSelect: (index: number) => {
          if (this.locked()) { return; }
          this.archived = index === 1; this.visibleCounts = {}; this.selectedIds = [];
        } })
      }
      if (this.selecting) {
        Row({ space: Space.sm }) {
          Text(t('已选 {0} 项', [this.selectedIds.length])).fontFamily(this.appearance.fontFamily).id('thread-selection-count')
            .fontSize(Font.small).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(this.allSelected() ? t('取消全选') : t('全选')).fontFamily(this.appearance.fontFamily).id('thread-select-all').attributeModifier(Btn.textSmall)
            .enabled(!this.locked() && this.filtered().length > 0).onClick(() => this.selectAll())
        }.width('100%')
      }
      if (this.sections(this.filtered()).length === 0) {
        Column({ space: Space.sm }) {
          SymbolGlyph(this.query.trim().length > 0 ? $r('sys.symbol.magnifyingglass') : $r('sys.symbol.ellipsis_message'))
            .fontSize(32).fontColor([$r('app.color.text_tertiary')])
          Text(this.query.trim().length > 0 ? t("没有匹配的对话") : this.archived ? t("没有归档的对话") : t("还没有对话")).fontFamily(this.appearance.fontFamily)
            .fontSize(Font.small).fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          // Retained ForEach nodes may capture IDs, never a derived section/array snapshot.
          ForEach(this.sections(this.filtered()).map((section) => section.id),
            (id: string) => {
              ListItemGroup({ header: this.sectionHeader(id), space: 0 }) {
                if (this.groupOpen(id)) {
                  ForEach(this.sectionThreads(id).slice(0, this.visibleCount(id)), (thread: ThreadViewModel) => {
                    ListItem() { ThreadRow({ thread: thread, app: this.app, workbench: this.workbench, query: this.query, onSelected: this.onSelected,
                      selecting: this.selecting, selected: this.selectedIds.includes(thread.id),
                      onSelectionChanged: (selected: boolean) => this.selectThread(thread.id, selected),
                      lastBranch: this.lastBranch(id, thread.id),
                      activePath: this.onActivePath(id, thread.id) }) }
                      .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fast, curve: Motion.standard }))
                  }, (thread: ThreadViewModel) => thread.id)
                  if (this.sectionThreads(id).length === 0) {
                    ListItem() { Text(t('还没有对话')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_tertiary'))
                      .padding({ left: 32, top: 8, bottom: 16 }) }
                  }
                  if (this.sectionThreads(id).length > this.visibleCount(id)) {
                    ListItem() {
                      Button(t('加载更多对话')).fontFamily(this.appearance.fontFamily).id('load-more-threads-' + (id || 'ordinary')).attributeModifier(Btn.textSmall)
                        .margin({ left: 28 }).onClick(() => this.loadMore(id))
                    }
                  }
                }
              }
            }, (id: string) => id || 'ordinary')
        }.id('project-thread-tree').layoutWeight(1).width('100%').scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      if (this.app.saveError.length > 0) {
        Banner({ text: this.app.saveError, actionLabel: t("重试"), actionEnabled: !this.app.sharedBusy,
          onAction: () => { this.app.retrySave(); } })
      } else if (this.app.error.length > 0) {
        Banner({ text: this.app.error })
      }
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      if (this.selecting) {
        Row({ space: Space.sm }) {
          Button(this.archived ? t('恢复对话') : t('归档')).fontFamily(this.appearance.fontFamily).id('thread-batch-archive')
            .attributeModifier(Btn.tonal).layoutWeight(1).enabled(!this.locked() && this.selectedIds.length > 0)
            .onClick(() => this.archiveSelected())
          Button(t('删除')).fontFamily(this.appearance.fontFamily).id('thread-batch-delete').attributeModifier(Btn.danger).layoutWeight(1)
            .enabled(!this.locked() && this.selectedIds.length > 0).onClick(() => this.confirmDeleteSelected())
        }.width('100%')
      } else {
        Row({ space: Space.md }) {
          SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          Text(t("设置")).fontFamily(this.appearance.fontFamily).fontSize(15).layoutWeight(1).fontColor($r('app.color.text_primary'))
          Text(t("{0} 个服务", [this.app.providerProfiles.length])).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
        }
        .id('open-settings').width('100%').height(48).padding({ left: Space.md, right: Space.md }).borderRadius(Radius.md)
        .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
        .onClick(() => this.onSettings())
        if (this.app.productivity.options?.miniAppsEnabled === true) {
          Button(t('小程序')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.tonal).width('100%')
            .id('open-mini-apps').enabled(this.app.ready).onClick(this.onMiniApps)
        }
      }
    }
    .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
    .height('100%').width('100%').backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.projectEditing, this.projectEditor(), { title: { title: this.projectId ? t('编辑项目') : t('新建项目') },
      detents: [SheetSize.LARGE], dragBar: true, keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY })
  }
}
