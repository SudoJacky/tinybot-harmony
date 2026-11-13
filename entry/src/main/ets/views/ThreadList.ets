import { materialMenuContent } from '../common/MaterialMenu';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { IS_PC } from '../common/DeviceForm';
import { t } from '../model/I18n';
import { FrameCallback, SymbolGlyphModifier } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { Diagnostics } from '../model/Diagnostics';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { ProjectData } from '../model/Project';
import { MAX_PROJECT_SHARED_FOLDERS, SharedFolder, sharedFolderNameFromUri, uniqueSharedFolderName } from '../model/SharedFolders';
import { ProjectFolderAccess } from '../services/ProjectFolderAccess';
import { Cancellation } from '../services/Cancellation';
import { webDavSettings, webDavShareRoot, WebDavSettings } from '../services/WebDavConnection';
import { listWebDavDirectory, WebDavDirectoryEntry } from '../services/WebDavWorkspaceFiles';
import { Btn, Font, Motion, Radius, Space, Styles } from '../common/Theme';
import { Banner, BottomBar, EmptyState, GroupCard, IconButton, NavRow, RowDivider, SectionHeader } from '../common/Widgets';

const SEARCH_HEIGHT: number = IS_PC ? 36 : 44;
const THREAD_ROW_HEIGHT: number = IS_PC ? 34 : 38;
const RENAME_CONTROL_HEIGHT: number = 36;
const ROW_MENU_SIZE: number = IS_PC ? 28 : 32;
const ROW_MENU_RIGHT_INSET: number = 4;

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
  @Prop conversationActive: boolean = true;
  @Prop selecting: boolean = false;
  @Prop selected: boolean = false;
  @State private rowHeight: number = THREAD_ROW_HEIGHT;
  @ObjectLink thread: ThreadViewModel;
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  onSelectionChanged: (selected: boolean) => void = () => {};
  @State private editing: boolean = false;
  @State private name: string = '';
  @State private hovered: boolean = false;

  private locked(): boolean {
    return !this.app.canNavigate;
  }

  private active(): boolean {
    return this.conversationActive && this.app.active.id === this.thread.id;
  }
  private matchId(): string { return this.thread.messages.find((item) => item.content.toLocaleLowerCase().includes(this.query.trim().toLocaleLowerCase()))?.id || ''; }

  @Builder
  actions() {
    Menu() {
      if (!this.selecting && !this.locked()) {
        MenuItem(() => materialMenuContent.bind(this)({ label: t("重命名"), icon: $r('sys.symbol.square_and_pencil') }))
          .onClick(() => { this.name = this.thread.title; this.editing = true; })
        MenuItem(() => materialMenuContent.bind(this)({ label: this.thread.pinned ? t("取消置顶") : t("置顶"), icon: $r('sys.symbol.pin') }))
          .onClick(() => this.app.pinThread(this.thread.id))
        MenuItem(() => materialMenuContent.bind(this)({ label: this.thread.archived ? t("恢复对话") : t("归档"), icon: $r('sys.symbol.archivebox') }))
          .enabled(!this.app.runningThreadIds.includes(this.thread.id))
          .onClick(() => this.app.archiveThread(this.thread.id))
        MenuItem(() => materialMenuContent.bind(this)({ label: t("删除"), icon: $r('sys.symbol.trash'), danger: true }))
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
      TextInput({ text: this.name, placeholder: t("对话名称") }).fontFamily(this.appearance.fontFamily).maxLength(80)
        .layoutWeight(1).height(RENAME_CONTROL_HEIGHT)
        .fontSize(15).backgroundColor($r('app.color.surface')).defaultFocus(true)
        .onChange((value: string) => { this.name = value; })
        .onSubmit(async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.xmark'), label: t("取消"), diameter: RENAME_CONTROL_HEIGHT, iconSize: 18,
        tint: $r('app.color.text_secondary'), onTap: () => { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.checkmark'), label: t("保存名称"), diameter: RENAME_CONTROL_HEIGHT, iconSize: 18,
        tint: this.appearance.accent, disabled: this.locked(),
        onTap: async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } } })
    }.width('100%').padding({ left: Space.sm, right: 4, top: 1, bottom: 1 }).constraintSize({ minHeight: THREAD_ROW_HEIGHT })
  }

  build() {
    Stack({ alignContent: Alignment.End }) {
    Column() {
      if (this.editing && !this.selecting) {
        this.renameEditor()
      } else {
        Row() {
          Stack({ alignContent: Alignment.Start }) {
            Checkbox({ name: this.thread.id }).id('thread-select-' + this.thread.id).select(this.selected)
              .shape(CheckBoxShape.CIRCLE).selectedColor(this.appearance.accent).width(22).height(22)
              .margin(0).opacity(this.selecting ? 1 : 0)
              .animation({ duration: Motion.fast, curve: Motion.standard, delay: this.selecting ? 60 : 0 })
              .enabled(this.selecting && !this.locked()).accessibilityText(this.thread.displayTitle)
              .accessibilityLevel(this.selecting ? 'auto' : 'no')
              .onChange((value: boolean) => { if (this.selecting && !this.locked()) { this.onSelectionChanged(value); } })
          }.width(this.selecting ? 30 : 0).height(32).clip(true)
            .animation({ duration: Motion.medium, curve: Motion.standard })
            .hitTestBehavior(this.selecting ? HitTestMode.Default : HitTestMode.None)
          Row({ space: 4 }) {
            if (this.app.runningThreadIds.includes(this.thread.id)) {
              LoadingProgress().width(14).height(14).color(this.appearance.accent).accessibilityText(t('正在执行'))
            }
            if (this.thread.pinned) {
              SymbolGlyph($r('sys.symbol.pin_fill')).fontSize(13).fontColor([this.appearance.accent])
            }
            Text(this.thread.displayTitle).fontFamily(this.appearance.fontFamily).fontSize(IS_PC ? 13 : 15).maxLines(1).layoutWeight(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontWeight(this.active() ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.workbench ? $r('app.color.text_primary') : this.active() ? this.appearance.onAccentContainer : $r('app.color.text_primary'))
          }.layoutWeight(1)
          if (!this.selecting) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
            }.id('thread-actions-' + this.thread.id).fontFamily(this.appearance.fontFamily)
            .width(ROW_MENU_SIZE).height(ROW_MENU_SIZE).margin({ left: Space.sm })
            .backgroundColor(Color.Transparent).accessibilityText(t("对话管理"))
            .enabled(!this.locked()).bindMenu(this.actions, {
              systemMaterial: this.appearance.menu, mask: false })
          }
        }
        .width('100%').padding({ left: this.workbench && !this.thread.parentThreadId ? 28 : Space.md, right: ROW_MENU_RIGHT_INSET,
          top: 3, bottom: 3 }).constraintSize({ minHeight: THREAD_ROW_HEIGHT })
        .focusable(!this.locked())
        .onClick(async () => {
          if (this.locked()) { return; }
          if (this.selecting) { this.onSelectionChanged(!this.selected); return; }
          if (this.query.trim() ? await this.app.openMessage(this.thread.id, this.matchId(), this.query.trim()) : await this.app.selectThread(this.thread.id)) { this.onSelected(); }
        })
        .bindContextMenu(this.actions, IS_PC ? ResponseType.RightClick : ResponseType.LongPress, {
          systemMaterial: this.appearance.menu, mask: false })
      }
    }
    .width(this.workbench && !this.thread.parentThreadId ? '100%' : 'calc(100% - 28vp)').borderRadius(this.workbench ? 10 : Radius.md)
    .backgroundColor((this.selecting ? this.selected : this.active()) ? $r('app.color.selection')
      : IS_PC && this.hovered && !this.locked() ? $r('app.color.surface_variant') : Color.Transparent)
    .onHover((hovered: boolean) => { if (IS_PC) { this.hovered = hovered; } })
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
  @Prop selectedSection: string = '';
  @Prop @Watch('searchAvailabilityChanged') active: boolean = true;
  @StorageProp('tinybot.foreground') @Watch('searchAvailabilityChanged') private foreground: boolean = true;
  @Prop workbench: boolean = false;
  // The persistent workbench column can collapse itself into the rail; the overlay
  // drawer cannot, so it omits the control.
  @Prop collapseHistory: boolean = false;
  @Prop @Watch('searchRequested') searchRequest: number = 0;
  @State @Watch('searchVisibilityChanged') private searchOpen: boolean = false;
  @State private toolbarWidth: number = SEARCH_HEIGHT;
  private mounted: boolean = false;
  private focusRequest: number = 0;
  onCollapseHistory: () => void = () => {};
  onNewChat: (projectId?: string) => void = () => {};
  onTools: () => void = () => {};
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  onSettings: () => void = () => {};
  onLifePanels: () => void = () => {};
  onFiles: () => void = () => {};
  onProjectSheetVisibility: (visible: boolean) => void = () => {};
  @State private query: string = '';
  @State private archived: boolean = false;
  @State private projectFilter: string | null = null;
  @State private selecting: boolean = false;
  @State private selectedIds: string[] = [];
  @State private visibleCounts: Record<string, number> = {};
  @State private collapsedProjects: string[] = [];
  @State @Watch('projectEditorChanged') private projectEditing: boolean = false;
  @State private projectId: string = '';
  @State private projectName: string = '';
  @State private projectInstructions: string = '';
  @State private projectFolders: SharedFolder[] = [];
  @State private projectFolderError: string = '';
  @State private webDavConnections: WebDavSettings[] = [];
  @State private choosingCloudConnection: boolean = false;
  @State private cloudPath: WebDavDirectoryEntry[] = [];
  @State private cloudEntries: WebDavDirectoryEntry[] = [];
  @State private cloudLoading: boolean = false;
  @State private cloudListed: boolean = false;
  private cloudConnectionId: string = '';
  private cloudRequest?: Cancellation;
  private projectConnectionLoad: number = 0;

  aboutToAppear(): void {
    this.mounted = true;
    if (this.searchRequest > 0) { this.searchRequested(); }
  }
  aboutToDisappear(): void { this.mounted = false; this.focusRequest++; this.closeCloudPicker(); }
  private searchAvailabilityChanged(): void { if (!this.active || !this.foreground) { this.focusRequest++; } }
  private searchVisibilityChanged(): void { if (!this.searchOpen) { this.focusRequest++; } }

  // The rail can mount the search field and request its focus in the same frame.
  private searchRequested(): void {
    if (this.locked()) { return; }
    if (this.selecting) { this.endSelection(); }
    this.searchOpen = true;
    const request = ++this.focusRequest;
    this.getUIContext().postFrameCallback(new ThreadSearchFrame(() => {
      if (request !== this.focusRequest || !this.mounted || !this.searchOpen || !this.active || !this.foreground || this.locked()) { return; }
      Diagnostics.log('debug', 'focus', 'search_requested', { request: request });
      this.getUIContext().getFocusController().requestFocus('search-threads');
    }));
  }

  private closeSearch(): void {
    if (!this.searchOpen) { return; }
    this.searchOpen = false;
    this.getUIContext().getFocusController().clearFocus();
    this.updateQuery('');
  }

  private updateQuery(query: string): void {
    if (this.query === query) { return; }
    this.query = query;
    this.visibleCounts = {};
    this.selectedIds = [];
  }

  private setScope(archived: boolean, project: string | null): void {
    if (this.archived === archived && this.projectFilter === project) { return; }
    this.archived = archived;
    this.projectFilter = project;
    this.visibleCounts = {};
    this.selectedIds = [];
  }

  private filtered(): ThreadViewModel[] {
    const threads = this.app.filteredThreads(this.query, this.archived);
    const project = this.projectFilter;
    if (project === null) { return threads; }
    const projectIds = new Set(this.app.projects.map((item) => item.id));
    return threads.filter((thread) => this.threadProject(thread, projectIds) === project);
  }

  private threadProject(thread: ThreadViewModel, projects: Set<string>): string {
    const project = thread.projectId || '';
    return projects.has(project) ? project : '';
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
    return this.filtered().filter((thread) => this.threadProject(thread, projectIds) === id);
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
    this.closeCloudPicker();
    this.webDavConnections = [];
    this.projectEditing = true;
    const load = ++this.projectConnectionLoad;
    webDavSettings().then((settings) => {
      if (this.projectEditing && this.projectConnectionLoad === load) { this.webDavConnections = settings; }
    }).catch((error: Error) => {
      if (this.projectEditing && this.projectConnectionLoad === load) { this.projectFolderError = error.message; }
    });
  }

  private openCloudPicker(): void {
    if (this.locked() || this.cloudLoading) { return; }
    if (this.webDavConnections.length === 1) { this.openCloudConnection(this.webDavConnections[0]); }
    else { this.choosingCloudConnection = true; }
  }

  private async openCloudConnection(connection: WebDavSettings): Promise<void> {
    if (this.locked() || this.cloudLoading) { return; }
    const pending = new Cancellation();
    this.cloudRequest = pending;
    this.cloudLoading = true;
    this.projectFolderError = '';
    try {
      const root = await webDavShareRoot(connection.id);
      if (!this.projectEditing || this.cloudRequest !== pending) { return; }
      this.cloudConnectionId = root.id;
      connection.grantId = root.id;
      this.choosingCloudConnection = false;
      await this.browseCloud([{ name: connection.name, uri: root.directory, kind: 'directory' }]);
    } catch (error) {
      if (this.cloudRequest === pending) { this.projectFolderError = (error as Error).message; }
    } finally {
      if (this.cloudRequest === pending) { this.cloudLoading = false; }
    }
  }

  private async browseCloud(path: WebDavDirectoryEntry[]): Promise<void> {
    this.cloudRequest?.cancel();
    const request = new Cancellation();
    this.cloudRequest = request;
    this.cloudPath = path;
    this.cloudEntries = [];
    this.cloudListed = false;
    this.cloudLoading = true;
    this.projectFolderError = '';
    try {
      const entries = await listWebDavDirectory(this.cloudConnectionId, path[path.length - 1].uri, request);
      if (this.cloudRequest !== request) { return; }
      this.cloudEntries = entries.filter((entry) => entry.kind === 'directory');
      this.cloudListed = true;
    } catch (error) {
      if (this.cloudRequest === request) { this.projectFolderError = (error as Error).message; }
    } finally {
      if (this.cloudRequest === request) { this.cloudLoading = false; }
    }
  }

  private closeCloudPicker(): void {
    const request = this.cloudRequest;
    this.cloudRequest = undefined;
    request?.cancel();
    this.cloudPath = []; this.cloudEntries = []; this.cloudListed = false; this.cloudLoading = false;
    this.choosingCloudConnection = false;
    this.projectFolderError = '';
  }

  private projectEditorChanged(): void { if (!this.projectEditing) { this.closeCloudPicker(); } }

  private cloudFolderAdded(): boolean {
    const current = this.cloudPath[this.cloudPath.length - 1];
    return current !== undefined && this.projectFolders.some((folder) =>
      folder.uri === current.uri && folder.webDavConnectionId === this.cloudConnectionId);
  }

  private cloudBack(): void {
    if (this.cloudPath.length > 1) { this.browseCloud(this.cloudPath.slice(0, -1)); return; }
    this.closeCloudPicker();
    this.choosingCloudConnection = this.webDavConnections.length > 1;
  }

  private projectFolderSource(folder: SharedFolder): string {
    if (folder.webDavConnectionId === undefined) { return t('本地文件夹'); }
    return this.webDavConnections.find((connection) => connection.grantId === folder.webDavConnectionId)?.name || t('WebDAV');
  }

  private selectCloudFolder(): void {
    if (!this.cloudListed || !this.cloudPath.length || this.locked()) { return; }
    const chosen = this.cloudPath[this.cloudPath.length - 1];
    if (this.cloudFolderAdded()) { return; }
    if (this.projectFolders.length >= MAX_PROJECT_SHARED_FOLDERS) { return; }
    const name = this.cloudPath.length === 1 ? t('WebDAV 根目录') : chosen.name;
    this.projectFolders = this.projectFolders.concat({
      id: util.generateRandomUUID(), name: uniqueSharedFolderName(name, this.projectFolders),
      uri: chosen.uri, addedAt: Date.now(), webDavConnectionId: this.cloudConnectionId
    });
    this.closeCloudPicker();
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
    Row({ space: Space.md }) {
      SymbolGlyph(folder.webDavConnectionId === undefined ? $r('sys.symbol.folder') : $r('sys.symbol.cloud'))
        .fontSize(20).fontColor([this.appearance.accent]).width(28).accessibilityLevel('no')
      Column({ space: 2 }) {
        Text(folder.name).fontFamily(this.appearance.fontFamily).fontSize(Font.body).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Text(this.projectFolderSource(folder)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button(t('移除')).fontFamily(this.appearance.fontFamily).id('project-remove-folder-' + folder.id)
        .attributeModifier(Btn.textSmall).constraintSize({ minHeight: 44 }).accessibilityText(t('移除') + ' ' + folder.name)
        .enabled(!this.locked()).onClick(() => this.removeProjectFolder(folder.id))
    }.width('100%').constraintSize({ minHeight: 60 }).padding({ left: Space.lg, right: Space.md, top: 6, bottom: 6 })
  }

  @Builder
  cloudConnectionPicker() {
    Column() {
      Row({ space: Space.md }) {
        IconButton({ icon: $r('sys.symbol.chevron_left'), label: t('返回项目'), compId: 'project-cloud-connection-back',
          onTap: () => this.closeCloudPicker() })
      }.width('100%').padding({ left: Space.md, right: Space.lg, bottom: Space.sm })
      Scroll() {
        Column({ space: Space.md }) {
          GroupCard() {
            Column() {
              ForEach(this.webDavConnections, (connection: WebDavSettings, index: number) => {
                if (index > 0) { RowDivider() }
                NavRow({ title: connection.name, subtitle: connection.username + ' · ' + connection.directory,
                  icon: $r('sys.symbol.cloud'), compId: 'project-cloud-connection-' + index,
                  disabled: this.cloudLoading, onTap: () => this.openCloudConnection(connection) })
              }, (connection: WebDavSettings) => connection.id)
            }
          }
          if (this.projectFolderError) { Banner({ text: this.projectFolderError }) }
        }.width('100%').padding({ left: Space.lg, right: Space.lg, bottom: Space.lg })
      }.width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%')
  }

  @Builder
  cloudFolderPicker() {
    Column() {
      Row({ space: Space.md }) {
        IconButton({ icon: $r('sys.symbol.chevron_left'), compId: 'project-cloud-back',
          label: this.cloudPath.length > 1 ? t('上一级') : this.webDavConnections.length > 1 ? t('返回连接列表') : t('返回项目'),
          onTap: () => this.cloudBack() })
        Column({ space: 3 }) {
          Text(this.cloudPath[this.cloudPath.length - 1]?.name || t('WebDAV 根目录'))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.cloudPath.length > 1) {
            Text(this.cloudPath.slice(0, -1).map((entry: WebDavDirectoryEntry) => entry.name).join(' / '))
              .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(t('取消')).attributeModifier(Btn.textSmall).constraintSize({ minHeight: 44 }).onClick(() => this.closeCloudPicker())
      }.width('100%').padding({ left: Space.md, right: Space.lg, bottom: Space.sm })
      Scroll() {
        Column({ space: Space.md }) {
          if (this.cloudLoading) {
            Row({ space: Space.sm }) {
              LoadingProgress().width(20).height(20).color(this.appearance.accent)
              Text(t('正在读取云端目录…')).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
                .fontColor($r('app.color.text_secondary'))
            }.width('100%').justifyContent(FlexAlign.Center).padding(Space.xl)
          } else if (this.projectFolderError) {
            Banner({ text: this.projectFolderError, actionLabel: t('重试'), actionId: 'project-cloud-retry',
              onAction: () => this.browseCloud(this.cloudPath.slice()) })
          } else if (this.cloudEntries.length === 0) {
            EmptyState({ icon: $r('sys.symbol.folder'), title: t('没有子文件夹'), caption: t('可以将当前文件夹添加到项目。') })
          } else {
            GroupCard() {
              Column() {
                ForEach(this.cloudEntries, (entry: WebDavDirectoryEntry, index: number) => {
                  if (index > 0) { RowDivider() }
                  NavRow({ title: entry.name, icon: $r('sys.symbol.folder'), compId: 'project-cloud-folder-' + index,
                    onTap: () => this.browseCloud(this.cloudPath.concat(entry)) })
                }, (entry: WebDavDirectoryEntry) => entry.uri)
              }
            }
          }
        }.width('100%').padding({ left: Space.lg, right: Space.lg, top: Space.sm, bottom: Space.lg })
      }.width('100%').layoutWeight(1).align(Alignment.Top)
      BottomBar({ sheet: true }) {
        Button(this.cloudFolderAdded() ? t('已添加到项目') : t('添加当前文件夹')).id('project-cloud-select')
          .attributeModifier(Btn.primary).width('100%')
          .enabled(this.cloudListed && !this.cloudFolderAdded() && !this.app.sharedBusy).onClick(() => this.selectCloudFolder())
      }
    }.width('100%').height('100%')
  }

  @Builder
  projectEditor() {
    if (this.cloudPath.length > 0) {
      this.cloudFolderPicker()
    } else if (this.choosingCloudConnection) {
      this.cloudConnectionPicker()
    } else {
      Column() {
        Scroll() {
          Column() {
            SectionHeader({ title: t('项目信息') })
            GroupCard() {
              Column({ space: Space.sm }) {
                Text(t('项目名称')).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
                  .fontColor($r('app.color.text_secondary')).width('100%')
                TextInput({ text: this.projectName, placeholder: t('项目名称') }).id('project-name').maxLength(80)
                  .attributeModifier(Styles.input).accessibilityText(t('项目名称'))
                  .onChange((value: string) => { this.projectName = value; })
                Text(t('项目说明与约定（可选）')).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
                  .fontColor($r('app.color.text_secondary')).width('100%').margin({ top: Space.xs })
                TextArea({ text: this.projectInstructions }).fontFamily(this.appearance.fontFamily).id('project-instructions')
                  .fontSize(Font.body).height(92).maxLength(16000).borderRadius(Radius.sm)
                  .backgroundColor($r('app.color.surface_variant')).fontColor($r('app.color.text_primary'))
                  .accessibilityText(t('项目说明与约定（可选）'))
                  .onChange((value: string) => { this.projectInstructions = value; })
              }.width('100%').padding(Space.md)
            }
            SectionHeader({ title: t('共享文件夹'),
              caption: this.webDavConnections.length > 0 || this.projectFolders.some((folder) => folder.webDavConnectionId !== undefined) ?
                t('云端文件夹仅对本项目开放，写入遵循会话的工具审批设置。') : t('项目内的会话可以读写这些文件夹。') })
            GroupCard() {
              Column() {
                ForEach(this.projectFolders, (folder: SharedFolder) => {
                  this.projectFolderRow(folder)
                  RowDivider()
                }, (folder: SharedFolder) => folder.id)
                NavRow({ title: t('添加本地文件夹'), icon: $r('sys.symbol.folder_badge_plus'), compId: 'project-add-folder',
                  disabled: this.locked() || this.projectFolders.length >= MAX_PROJECT_SHARED_FOLDERS, onTap: () => this.addProjectFolders() })
                if (this.webDavConnections.length > 0) {
                  RowDivider()
                  NavRow({ title: this.cloudLoading ? t('正在读取云端目录…') : t('添加 WebDAV'),
                    icon: $r('sys.symbol.cloud'), compId: 'project-add-cloud-folder',
                    disabled: this.app.sharedBusy || this.cloudLoading || this.projectFolders.length >= MAX_PROJECT_SHARED_FOLDERS,
                    onTap: () => this.openCloudPicker() })
                }
              }
            }
            if (this.projectFolders.length >= MAX_PROJECT_SHARED_FOLDERS) {
              Text(t('每个项目最多添加 {0} 个共享文件夹。', [MAX_PROJECT_SHARED_FOLDERS]))
                .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
                .width('100%').margin({ top: Space.sm })
            }
            if (this.projectFolderError.length > 0) { Banner({ text: this.projectFolderError }).margin({ top: Space.sm }) }
            if (this.app.error) { Banner({ text: this.app.error }).margin({ top: Space.sm }) }
          }.width('100%').padding({ left: Space.lg, right: Space.lg, bottom: Space.lg })
        }.width('100%').layoutWeight(1).align(Alignment.Top)
        BottomBar({ sheet: true }) {
          Button(t('保存')).fontFamily(this.appearance.fontFamily).id('project-save').attributeModifier(Btn.primary).width('100%')
            .enabled(!this.app.sharedBusy && !this.app.saveError && this.projectName.trim().length > 0)
            .onClick(async () => {
              const creating = !this.projectId;
              if (await this.app.saveProject(this.projectName, this.projectInstructions, this.projectId || undefined, this.projectFolders)) {
                const id = this.projectId || this.app.active.projectId || '';
                // A newly created project must be visible even when launched from search or archives.
                if (creating) { this.updateQuery(''); this.setScope(false, null); }
                this.collapsedProjects = this.collapsedProjects.filter((item) => item !== id);
                this.projectEditing = false;
              }
            })
        }
      }.width('100%').height('100%')
    }
  }

  private sections(threads: ThreadViewModel[]): ThreadSection[] {
    const result = this.app.projects.map((project) => new ThreadSection(project.id, project.name));
    const ordinary = new ThreadSection('', t('普通聊天'));
    result.push(ordinary);
    for (const thread of threads) {
      const section = result.find((item: ThreadSection) => item.id === (thread.projectId || '')) || ordinary;
      section.threads.push(thread);
    }
    return result.filter((section) => (this.projectFilter === null || section.id === this.projectFilter) &&
      (!(this.query.trim() || this.archived) || section.threads.length > 0));
  }

  @Builder
  projectActions(id: string) {
    Menu() {
      if (IS_PC && !this.archived) {
        MenuItem(() => materialMenuContent.bind(this)({ label: t('在此项目中新建对话'), icon: $r('sys.symbol.square_and_pencil') }))
          .enabled(!this.locked()).onClick(() => this.onNewChat(id))
      }
      MenuItem(() => materialMenuContent.bind(this)({ label: t('项目文件'), icon: $r('sys.symbol.folder') }))
        .onClick(async () => { if (await this.app.openProject(id)) { this.onFiles(); } })
      MenuItem(() => materialMenuContent.bind(this)({ label: t('编辑项目'), icon: $r('sys.symbol.square_and_pencil') }))
        .onClick(() => this.editProject(id))
    }
  }

  @Builder
  scopeMenu() {
    Menu() {
      MenuItem(() => materialMenuContent.bind(this)({ label: t('对话'), selected: !this.archived }))
        .id('active-threads').onClick(() => this.setScope(false, this.projectFilter))
      MenuItem(() => materialMenuContent.bind(this)({ label: t('已归档'), selected: this.archived }))
        .id('archived-threads').onClick(() => this.setScope(true, this.projectFilter))
      MenuItemGroup() {
        MenuItem(() => materialMenuContent.bind(this)({ label: t('全部项目'), selected: this.projectFilter === null }))
          .id('threads-all-projects').onClick(() => this.setScope(this.archived, null))
        MenuItem(() => materialMenuContent.bind(this)({ label: t('普通聊天'), selected: this.projectFilter === '' }))
          .id('threads-ordinary').onClick(() => this.setScope(this.archived, ''))
        ForEach(this.app.projects, (project: ProjectData) => {
          MenuItem(() => materialMenuContent.bind(this)({ label: project.name, selected: this.projectFilter === project.id }))
            .id('threads-project-' + project.id).onClick(() => this.setScope(this.archived, project.id))
        }, (project: ProjectData) => project.id)
      }
      MenuItemGroup() {
        MenuItem({ content: t('多选'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.checkmark_circle')) })
          .id('thread-selection-mode').enabled(this.filtered().length > 0)
          .onClick(() => { this.selecting = true; })
        MenuItem({ content: t('新建项目'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder_badge_plus')) })
          .id('project-create').enabled(!this.app.sharedBusy && !this.app.saveError)
          .onClick(() => this.editProject())
      }
    }
  }

  @Builder
  workspaceMenu() {
    Menu() {
      MenuItem({ content: t('工作区文件'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder')) })
        .id('workbench-sidebar-files').onClick(this.onFiles)
      MenuItem({ content: t('记忆与工具'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.wrench_and_screwdriver')) })
        .id('workbench-sidebar-tools').onClick(this.onTools)
    }
  }

  @Builder
  searchControl() {
    Row() {
      Stack() {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(19)
          .fontColor([$r('app.color.text_secondary')]).accessibilityLevel('no')
        if (!this.searchOpen) {
          Button({ type: ButtonType.Circle }).id('thread-search-toggle').width(SEARCH_HEIGHT).height(SEARCH_HEIGHT)
            .backgroundColor(Color.Transparent).accessibilityText(t('搜索对话')).enabled(!this.locked())
            .onClick(() => this.searchRequested())
        }
      }.width(SEARCH_HEIGHT).height(SEARCH_HEIGHT).flexShrink(0)
      TextInput({ text: this.query, placeholder: t('搜索对话') })
        .id('search-threads').layoutWeight(1).height(SEARCH_HEIGHT).padding(0)
        .fontFamily(this.appearance.fontFamily).fontSize(15).placeholderColor($r('app.color.text_tertiary'))
        .backgroundColor(Color.Transparent).enabled(this.searchOpen && !this.locked()).focusable(this.searchOpen)
        .visibility(this.searchOpen ? Visibility.Visible : Visibility.None).accessibilityText(t('搜索对话'))
        .onChange((value: string) => { if (this.searchOpen) { this.updateQuery(value); } })
        .onKeyEvent((event: KeyEvent) => {
          if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
            this.closeSearch();
            event.stopPropagation();
          }
        })
      if (this.searchOpen) {
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭搜索'), compId: 'close-thread-search',
          diameter: SEARCH_HEIGHT, iconSize: 15, onTap: () => this.closeSearch() })
      }
    }.id('thread-search-pill').width(this.searchOpen ? this.toolbarWidth : SEARCH_HEIGHT).height(SEARCH_HEIGHT)
      .borderRadius(SEARCH_HEIGHT / 2).clip(true).backgroundColor($r('app.color.surface_variant'))
      .animation({ duration: Motion.fast, curve: Motion.standard })
  }

  @Builder
  historyToolbar() {
    if (this.selecting) {
      Row({ space: Space.sm }) {
        Text(t('已选中 {0} 个会话', [this.selectedIds.length])).fontFamily(this.appearance.fontFamily).id('thread-selection-count')
          .fontSize(Font.small).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('取消'), compId: 'thread-selection-cancel', diameter: SEARCH_HEIGHT,
          iconSize: 17, onTap: () => this.endSelection() })
      }.width('100%').height(SEARCH_HEIGHT)
    } else {
      Stack({ alignContent: Alignment.Start }) {
        Row() {
          Blank().layoutWeight(1)
          IconButton({ icon: $r('sys.symbol.square_grid_2x2'), label: t('生活看板'), compId: 'open-life-panels',
            diameter: SEARCH_HEIGHT, iconSize: 19, disabled: !this.app.ready, onTap: this.onLifePanels })
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(18)
              .fontColor([this.archived || this.projectFilter !== null ? this.appearance.accent : $r('app.color.text_secondary')])
          }.id('thread-scope-menu').width(SEARCH_HEIGHT).height(SEARCH_HEIGHT)
            .backgroundColor(this.archived || this.projectFilter !== null ? this.appearance.accentContainer : Color.Transparent)
            .accessibilityText(t('筛选对话')).enabled(!this.locked())
            .bindMenu(this.scopeMenu, { systemMaterial: this.appearance.menu, mask: false })
          IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t('新建对话'), compId: 'workbench-new-chat',
            diameter: SEARCH_HEIGHT, iconSize: 19, disabled: this.locked(), onTap: () => this.onNewChat(
              this.projectFilter === null && IS_PC ? this.app.activeProject?.id : this.projectFilter || undefined) })
          if (this.collapseHistory) {
            IconButton({ icon: $r('sys.symbol.close_sidebar'), label: t('收起会话栏'), compId: 'workbench-collapse-history',
              diameter: SEARCH_HEIGHT, iconSize: 18, onTap: this.onCollapseHistory })
          }
        }.width('100%').height(SEARCH_HEIGHT).enabled(!this.searchOpen)
          .accessibilityLevel(this.searchOpen ? 'no-hide-descendants' : 'auto')
        this.searchControl()
      }.width('100%').height(SEARCH_HEIGHT)
        .onAreaChange((_oldArea: Area, area: Area) => { this.toolbarWidth = Math.max(SEARCH_HEIGHT, Number(area.width)); })
    }
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
          if (IS_PC) {
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.groupOpen(id) ? 0 : -90 }).accessibilityLevel('no')
          }
        }.width('100%')
      }.fontFamily(this.appearance.fontFamily).id('project-group-' + (id || 'ordinary')).layoutWeight(1).height(THREAD_ROW_HEIGHT).padding({ right: 4 })
        .backgroundColor(Color.Transparent).borderRadius(10).onClick(() => this.toggleGroup(id))
        .accessibilityText(this.sectionTitle(id) + '，' + (this.groupOpen(id) ? t('收起') : t('展开')))
      if (!this.selecting) {
        if (IS_PC && id && !this.archived) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(14).fontColor([$r('app.color.text_secondary')])
          }.id('pc-new-chat-in-' + id).width(ROW_MENU_SIZE).height(ROW_MENU_SIZE).padding(0).borderRadius(8)
            .backgroundColor(Color.Transparent).enabled(!this.locked())
            .accessibilityText(t('在此项目中新建对话') + ' · ' + this.sectionTitle(id))
            .onClick(() => this.onNewChat(id))
        }
        if (id) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.fontFamily(this.appearance.fontFamily).id('project-actions-' + id)
            .width(ROW_MENU_SIZE).height(ROW_MENU_SIZE).backgroundColor(Color.Transparent)
            .accessibilityText(t('编辑项目') + ' · ' + this.sectionTitle(id)).enabled(!this.app.sharedBusy && !this.app.saveError)
            .bindMenu(this.projectActions(id), { systemMaterial: this.appearance.menu, mask: false })
        }
      }
    }.width('100%').padding({ top: 2, right: ROW_MENU_RIGHT_INSET }).backgroundColor($r('app.color.page_background'))
  }

  build() {
    Column() {
      if (this.active) { this.listContent() }
    }.width('100%').height('100%')
  }

  @Builder
  listContent() {
    Column({ space: Space.sm }) {
      this.historyToolbar()
      if (this.archived || this.projectFilter !== null) {
        Row({ space: Space.sm }) {
          if (this.archived) {
            Text(t('已归档')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          }
          if (this.projectFilter !== null) {
            Text(this.sectionTitle(this.projectFilter)).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
              .fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.width('100%').padding({ left: Space.sm, right: Space.sm })
      }
      if (this.sections(this.filtered()).length === 0) {
        Column({ space: Space.sm }) {
          SymbolGlyph(this.query.trim().length > 0 ? $r('sys.symbol.magnifyingglass') : $r('sys.symbol.ellipsis_message'))
            .fontSize(32).fontColor([$r('app.color.text_tertiary')])
          Text(this.query.trim().length > 0 ? t("没有匹配的对话") : this.archived ? t("没有归档的对话") : t("还没有对话")).fontFamily(this.appearance.fontFamily)
            .fontSize(Font.small).fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 6 }) {
          // Retained ForEach nodes may capture IDs, never a derived section/array snapshot.
          ForEach(this.sections(this.filtered()).map((section) => section.id),
            (id: string) => {
              ListItemGroup({ header: this.sectionHeader(id), space: 0 }) {
                if (this.groupOpen(id)) {
                  ForEach(this.sectionThreads(id).slice(0, this.visibleCount(id)), (thread: ThreadViewModel) => {
                    ListItem() { ThreadRow({ thread: thread, app: this.app, conversationActive: this.selectedSection === '', workbench: this.workbench, query: this.query, onSelected: () => { this.closeSearch(); this.onSelected(); },
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
        }.id('project-thread-tree').layoutWeight(1).width('100%').scrollBar(IS_PC ? BarState.Auto : BarState.Off)
        .edgeEffect(IS_PC ? EdgeEffect.None : EdgeEffect.Spring)
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
          Button(this.allSelected() ? t('取消全选') : t('全选')).fontFamily(this.appearance.fontFamily).id('thread-select-all').attributeModifier(Btn.textSmall)
            .enabled(!this.locked() && this.filtered().length > 0).onClick(() => this.selectAll())
          Button(this.archived ? t('恢复对话') : t('归档')).fontFamily(this.appearance.fontFamily).id('thread-batch-archive')
            .attributeModifier(Btn.tonal).layoutWeight(1).enabled(!this.locked() && this.selectedIds.length > 0)
            .onClick(() => this.archiveSelected())
          Button(t('删除')).fontFamily(this.appearance.fontFamily).id('thread-batch-delete').attributeModifier(Btn.danger).layoutWeight(1)
            .enabled(!this.locked() && this.selectedIds.length > 0).onClick(() => this.confirmDeleteSelected())
        }.width('100%')
      } else {
        Row({ space: Space.xs }) {
          if (this.workbench) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.folder')).fontSize(20).fontColor([$r('app.color.text_secondary')])
            }.id('sidebar-workspace-menu').width(SEARCH_HEIGHT).height(SEARCH_HEIGHT).backgroundColor(Color.Transparent)
              .accessibilityText(t('工作区')).bindMenu(this.workspaceMenu, { systemMaterial: this.appearance.menu, mask: false })
          }
          Row({ space: Space.sm }) {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.text_secondary')])
            Text(t('设置')).fontFamily(this.appearance.fontFamily).fontSize(15).layoutWeight(1)
              .fontColor($r('app.color.text_primary')).maxLines(1)
            if (!IS_PC) {
              Text(t('已配置 {0} 个模型服务', [this.app.providerProfiles.length])).fontFamily(this.appearance.fontFamily)
                .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
            }
          }.id('open-settings').layoutWeight(1).height(IS_PC ? 36 : 48).padding({ left: Space.sm, right: Space.sm }).borderRadius(Radius.md)
            .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
            .onClick(this.onSettings)
        }.width('100%')
      }
    }
    .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
    .height('100%').width('100%').backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.projectEditing, this.projectEditor(), { radius: Radius.sheet, title: {
      title: this.cloudPath.length > 0 ? t('选择云端文件夹') : this.choosingCloudConnection ? t('选择 WebDAV 连接') :
        this.projectId ? t('编辑项目') : t('新建项目') },
      detents: [SheetSize.LARGE], dragBar: true, keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
      onWillAppear: () => this.onProjectSheetVisibility(true), onDisappear: () => this.onProjectSheetVisibility(false) })
  }
}
