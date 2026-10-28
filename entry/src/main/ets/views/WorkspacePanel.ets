import { AnimatedPage } from '../common/AnimatedPage';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { SwipeRow } from '../common/SwipeRow';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { NativeWorkspaceFiles } from '../services/NativeWorkspaceFiles';
import { Cancellation } from '../services/Cancellation';
import { writeBytes } from '../services/Attachments';
import { isDocumentPath } from '../services/DocumentFiles';
import { exportFile, shareFile } from '../services/NativeActions';
import { aiAssistedFile } from '../model/ConversationExport';
import { MarkdownView } from './MarkdownView';
import { DataTable } from './DataTable';
import { parseDelimited } from '../model/RichArtifacts';
import { FileBaseline, WorkspaceEntry } from '../services/WorkspaceFiles';
import { ToolFailure } from '../model/ToolFailure';
import { Diagnostics } from '../model/Diagnostics';
import { Btn, Font, Radius, Space, systemInsets } from '../common/Theme';
import { Banner, BottomBar, EmptyState, IconButton } from '../common/Widgets';

const IMAGE_FILE: RegExp = /\.(png|jpe?g|webp|gif|bmp)$/i;
const MARKDOWN_FILE: RegExp = /\.(md|markdown)$/i;

function pad(value: number): string { return value < 10 ? '0' + value : value.toString(); }

@Component
export struct WorkspacePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop initialPath: string = '';
  @Prop embedded: boolean = false;
  // The docked detail strip owns the title and close control; keep only the
  // file preview's own navigation inside the tab body.
  @Prop tabbed: boolean = false;
  @Prop @Watch('openRequested') requestId: number = 0;
  @Prop @Watch('backRequested') closeRequest: number = 0;
  // The docked tab's own close control skips the breadcrumb navigation that
  // Back performs and still runs the unsaved-changes guard.
  @Prop @Watch('tabCloseRequested') tabCloseRequest: number = 0;
  onClose: () => void = () => {};
  @State private workspaceTitle: string = '';
  private ownerWorkspaceId: string = '';
  private ownerProject: boolean = false;
  @ObjectLink app: ChatViewModel;
  @State private directory: string = '';
  @State private swipeRow: string = '';
  @State private entries: WorkspaceEntry[] = [];
  @State private selected: string = '';
  @State private content: string = '';
  @State private original: string = '';
  private version: string = '';
  @State private imagePath: string = '';
  @State private previewError: string = '';
  @State private previewing: boolean = false;
  @State private previewPresent: boolean = false;
  @State private editing: boolean = false;
  @State private busy: boolean = false;
  @State private refreshing: boolean = false;
  @State private error: string = '';
  @State private baseline: FileBaseline | undefined = undefined;
  @State private csv: string[][] = [];
  @State private selection: string = '';
  @State private selectedStart: number = 0;
  @State private truncated: boolean = false;
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  private files?: NativeWorkspaceFiles;
  aboutToAppear(): void {
    this.bindWorkspace();
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetTop = insets[0]; this.insetBottom = insets[1]; });
  }

  private bindWorkspace(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ownerWorkspaceId = this.app.activeWorkspaceId;
    this.ownerProject = !!this.app.activeProject;
    this.workspaceTitle = this.app.activeProject ? t('项目文件') + ' · ' + this.app.activeProject.name : t('工作区文件');
    this.files = new NativeWorkspaceFiles(new WorkspaceStore(context.getApplicationContext().filesDir).pathFor(this.ownerWorkspaceId),
      this.app.activeProject?.sharedFolders || []);
    this.directory = ''; this.previewing = false; this.editing = false; this.error = '';
    if (this.initialPath) {
      const slash = this.initialPath.lastIndexOf('/');
      this.directory = slash < 0 ? '' : this.initialPath.slice(0, slash);
      this.open({ name: this.initialPath.slice(slash + 1), kind: 'file' });
    }
    this.refresh();
  }

  private leave(action: () => void): void {
    if (this.busy) { return; }
    if (!this.dirty()) { action(); return; }
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('放弃未保存的修改？'),
      message: this.fileName(this.selected), primaryButton: { value: t('继续编辑'), action: () => {} },
      secondaryButton: { value: t('放弃'), fontColor: $r('app.color.danger'), action: action } });
  }
  private openRequested(): void { this.leave(() => this.bindWorkspace()); }
  private requestClose(): void { this.leave(this.onClose); }
  private tabCloseRequested(): void { this.requestClose(); }
  private backRequested(): void {
    if (this.busy) { return; }
    if (this.previewing) { this.closePreview(); }
    else if (this.directory) { this.go(this.crumbs().slice(0, -1).join('/')); }
    else { this.requestClose(); }
  }

  private locked(): boolean { return this.busy || this.app.busy; }
  private join(name: string): string { return (this.directory ? this.directory + '/' : '') + name; }
  private fileName(path: string): string { return path.split('/').pop() || t("文件.txt"); }
  private toast(message: string): void { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: message }); }
  private crumbs(): string[] { return this.directory ? this.directory.split('/') : []; }
  private dirty(): boolean { return this.editing && this.content !== this.original; }

  private mutationError(error: Error): string {
    Diagnostics.log('warn', 'workspace', 'mutation_failed', undefined, error);
    return error instanceof ToolFailure && (error.code === 'FS_STALE_VERSION' || error.code === 'FS_NOT_OBSERVED') ?
      t('文件已变化，请重新打开并检查。') : error.message;
  }

  private async refresh(): Promise<void> {
    if (!this.files) { return; }
    try {
      const files = this.files; const directory = this.directory;
      const list = await files.list(directory || '.', new Cancellation());
      if (files !== this.files || directory !== this.directory) { return; }
      // Folders first, then files, each alphabetical.
      this.entries = list.entries.sort((a, b) => (a.kind === 'directory' ? 0 : 1) - (b.kind === 'directory' ? 0 : 1) || a.name.localeCompare(b.name));
      this.truncated = list.truncated;
    } catch (error) { this.error = (error as Error).message; }
    finally { this.refreshing = false; }
  }
  private go(directory: string): void { if (this.busy) { return; } this.directory = directory; this.error = ''; this.refresh(); }

  private async open(entry: WorkspaceEntry): Promise<void> {
    if (!this.files || this.busy || entry.kind === 'symlink') { return; }
    const path = this.join(entry.name);
    if (entry.kind === 'directory') { this.go(path); return; }
    this.busy = true;
    this.selected = path; this.editing = false; this.content = ''; this.original = ''; this.version = ''; this.imagePath = ''; this.previewError = '';
    this.baseline = undefined; this.csv = []; this.selection = '';
    try {
      this.baseline = await this.files.baseline(path);
      if (IMAGE_FILE.test(entry.name)) { this.imagePath = await this.files.checkedPath(path); }
      else {
        const read = await this.files.read(path, new Cancellation());
        this.content = read.content; this.original = read.content; this.version = read.version;
      }
      if (/\.(csv|tsv)$/i.test(path)) { this.csv = parseDelimited(this.content, /\.tsv$/i.test(path) ? '\t' : ','); }
    } catch (error) { this.previewError = t("无法预览：") + (error as Error).message; }
    this.previewing = true; this.busy = false;
  }

  private uniqueName(name: string): string {
    const taken = new Set<string>(this.entries.map((entry) => entry.name));
    if (!taken.has(name)) { return name; }
    const dot = name.lastIndexOf('.'); const stem = dot > 0 ? name.slice(0, dot) : name; const ext = dot > 0 ? name.slice(dot) : '';
    let index = 2;
    while (taken.has(stem + ' (' + index + ')' + ext)) { index++; }
    return stem + ' (' + index + ')' + ext;
  }

  private async importFiles(): Promise<void> {
    if (!this.files || this.locked()) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true; this.error = '';
    try {
      const uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 5, fileSuffixFilters: [t("资料|.txt,.md,.csv,.tsv,.json,.log,.pdf,.docx,.xlsx,.pptx")] });
      if (!uris.length) { return; }
      let count = 0;
      for (const uri of uris) {
        let name = uri.slice(uri.lastIndexOf('/') + 1).split('?')[0];
        try { name = decodeURIComponent(name); } catch (_) { /* Keep literal URI name. */ }
        name = name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').slice(-80) || t("导入-") + Date.now() + '.txt';
        await this.files.importFile(uri, this.join(this.uniqueName(name)));
        count++; await this.refresh();
      }
      this.toast(t("已导入 ") + count + t(" 个文件"));
    } catch (error) { this.error = this.mutationError(error as Error); }
    finally { this.busy = false; await this.refresh(); }
  }

  private async newNote(): Promise<void> {
    if (!this.files || this.locked()) { return; }
    const now = new Date();
    const path = this.join(this.uniqueName(t("笔记-") + (now.getMonth() + 1) + pad(now.getDate()) + '-' + pad(now.getHours()) + pad(now.getMinutes()) + '.md'));
    this.busy = true; this.error = '';
    try {
      const saved = await this.files.write(path, '', new Cancellation(), { version: null }); await this.refresh();
      this.baseline = await this.files.baseline(path);
      this.selected = path; this.content = ''; this.original = ''; this.version = saved.version; this.imagePath = ''; this.previewError = '';
      this.editing = true; this.previewing = true;
    } catch (error) { this.error = this.mutationError(error as Error); }
    finally { this.busy = false; }
  }

  private async save(): Promise<void> {
    if (!this.files || this.locked()) { return; }
    this.busy = true;
    try {
      const content = this.content;
      const saved = await this.files.write(this.selected, content, new Cancellation(), { version: this.version });
      this.version = saved.version; this.original = content;
      this.baseline = await this.files.baseline(this.selected);
      this.editing = this.content !== content; this.previewError = ''; this.toast(t("已保存")); await this.refresh();
    } catch (error) {
      this.previewError = this.mutationError(error as Error);
      try { this.baseline = await this.files.baseline(this.selected); }
      catch (backupError) { this.previewError += '\n' + (backupError as Error).message; }
    }
    finally { this.busy = false; }
  }

  private async exportBaseline(): Promise<void> {
    if (!this.baseline?.existed || this.locked()) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const temporary = context.cacheDir + '/file-backup-' + util.generateRandomUUID() + '.txt';
    this.busy = true;
    try {
      const bytes: ArrayBuffer = this.baseline.content.length > 0 ?
        new util.TextEncoder().encodeInto(this.baseline.content).buffer as ArrayBuffer : new ArrayBuffer(0);
      await writeBytes(temporary, bytes);
      try { await exportFile(context, temporary, t('备份-') + this.fileName(this.selected)); }
      finally { await fs.unlink(temporary); }
    } catch (error) { this.previewError = (error as Error).message; }
    finally { this.busy = false; }
  }

  private async restoreBackup(): Promise<void> {
    if (!this.files || !this.baseline?.existed || this.locked() || this.editing || this.previewError) { return; }
    this.busy = true;
    try {
      await this.files.restore(this.selected, this.original);
      this.previewing = false; await this.refresh();
    } catch (error) { this.previewError = (error as Error).message; }
    finally { this.busy = false; }
  }

  private confirmRestore(): void {
    if (!this.baseline?.existed || this.locked() || this.editing || this.previewError) { return; }
    const scope = this.baseline.sourceUri ? t('共享文件将直接写回备份内容；恢复失败时备份会保留。') :
      this.ownerProject ? t('这会恢复项目中的累计修改，可能包含其他会话的改动。') : '';
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('恢复修改前版本？'),
      message: (scope ? scope + '\n' : '') + t('当前内容将被保存基线替换。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('恢复'), fontColor: $r('app.color.danger'), action: () => this.restoreBackup() } });
  }
  private reference(): void {
    if (this.embedded && this.app.activeWorkspaceId !== this.ownerWorkspaceId) {
      this.toast(t('请先切换回此文件所属的对话或项目。')); return;
    }
    const text = this.selection || this.content.slice(0, 4000);
    const line = this.content.slice(0, this.selectedStart).split('\n').length;
    this.app.setDraft(this.app.active.draft + t("\n\n引用文件 ") + this.selected + t("，第 ") + line + t(" 行附近：\n") + text.slice(0, 4000) + t("\n修改要求："));
    this.previewing = false; this.toast(t("引用已加入当前对话草稿"));
  }

  private async fileAction(kind: string, path: string, version: string = ''): Promise<void> {
    if (!this.files || this.locked()) { return; }
    this.busy = true; this.error = '';
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      if (kind === 'delete') {
        await this.files.remove(path, version);
        if (this.selected === path) { this.previewing = false; this.selected = ''; }
        this.toast(t("已删除"));
        return;
      }
      const absolute = await this.files.checkedPath(path);
      if (kind === 'export') {
        await exportFile(context, absolute, this.fileName(path),
          aiAssistedFile(this.app.exportSnapshot(), this.ownerWorkspaceId, path));
      }
      if (kind === 'share') { await shareFile(context, absolute, this.fileName(path)); }
    } catch (error) { if (this.previewing) { this.previewError = this.mutationError(error as Error); } else { this.error = this.mutationError(error as Error); } }
    finally { this.busy = false; await this.refresh(); }
  }

  private async confirmDelete(path: string): Promise<void> {
    if (!this.files || this.locked()) { return; }
    const files = this.files;
    this.busy = true; this.error = '';
    try {
      const version = await files.removalVersion(path);
      this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t("删除文件？"), message: this.fileName(path) + t("\n删除后无法恢复。"),
        primaryButton: { value: t("取消"), action: () => {} },
        secondaryButton: { value: t("删除"), fontColor: $r('app.color.danger'), action: async () => {
          if (files === this.files) { await this.fileAction('delete', path, version); }
        } } });
    } catch (error) { if (this.previewing) { this.previewError = this.mutationError(error as Error); } else { this.error = this.mutationError(error as Error); } }
    finally { this.busy = false; }
  }

  private closePreview(): void {
    if (!this.dirty()) { this.previewing = false; this.editing = false; return; }
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t("放弃未保存的修改？"), message: this.fileName(this.selected),
      primaryButton: { value: t("继续编辑"), action: () => {} },
      secondaryButton: { value: t("放弃"), fontColor: $r('app.color.danger'),
        action: () => { this.content = this.original; this.editing = false; this.previewing = false; } } });
  }

  private icon(entry: WorkspaceEntry): Resource {
    if (entry.kind === 'directory') { return $r('sys.symbol.folder_fill'); }
    if (IMAGE_FILE.test(entry.name)) { return $r('sys.symbol.picture'); }
    if (entry.kind === 'symlink') { return $r('sys.symbol.link'); }
    return MARKDOWN_FILE.test(entry.name) ? $r('sys.symbol.doc_plaintext') : $r('sys.symbol.doc_text');
  }

  private kindLabel(entry: WorkspaceEntry): string {
    if (entry.kind === 'directory') { return t("文件夹"); }
    if (entry.kind === 'symlink') { return t("链接 · 不支持打开"); }
    const dot = entry.name.lastIndexOf('.');
    return dot > 0 ? entry.name.slice(dot + 1).toUpperCase() + t(" 文件") : t("文件");
  }

  @Builder
  entryRow(entry: WorkspaceEntry) {
    Row({ space: Space.md }) {
      Column() {
        SymbolGlyph(this.icon(entry)).fontSize(22)
          .fontColor([entry.kind === 'directory' ? this.appearance.accent : $r('app.color.text_secondary')])
      }.width(40).height(40).borderRadius(Radius.sm).justifyContent(FlexAlign.Center)
      .backgroundColor(entry.kind === 'directory' ? this.appearance.accentContainer : $r('app.color.surface_variant'))
      Column({ space: 2 }) {
        Text(entry.name).fontFamily(this.appearance.fontFamily).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'))
        Text(this.kindLabel(entry)).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (entry.kind === 'directory') {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%').height(64).padding({ left: Space.page, right: Space.lg }).backgroundColor($r('app.color.surface'))
    .opacity(entry.kind === 'symlink' ? 0.5 : 1)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor($r('app.color.surface')) } })
    .onClick(() => this.open(entry))
  }

  @Builder
  breadcrumbs() {
    Scroll() {
      Row({ space: 2 }) {
        Text(t("工作区")).fontFamily(this.appearance.fontFamily).fontSize(14).padding({ left: 8, right: 8 }).height(32).borderRadius(16)
          .fontColor(this.directory ? this.appearance.accent : $r('app.color.text_primary'))
          .fontWeight(this.directory ? FontWeight.Normal : FontWeight.Medium)
          .onClick(() => { if (this.directory) { this.go(''); } })
        ForEach(this.crumbs(), (part: string, index: number) => {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_tertiary')])
          Text(part).fontFamily(this.appearance.fontFamily).fontSize(14).padding({ left: 8, right: 8 }).height(32).borderRadius(16).maxLines(1)
            .fontColor(index === this.crumbs().length - 1 ? $r('app.color.text_primary') : this.appearance.accent)
            .fontWeight(index === this.crumbs().length - 1 ? FontWeight.Medium : FontWeight.Normal)
            .onClick(() => { this.go(this.crumbs().slice(0, index + 1).join('/')); })
        }, (part: string, index: number) => index + part)
      }
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
    .padding({ left: Space.sm, right: Space.page })
  }

  @Builder
  toolbarButton(icon: Resource, label: string, compId: string, danger: boolean, action: () => void) {
    Column({ space: 3 }) {
      SymbolGlyph(icon).fontSize(22).fontColor([danger ? $r('app.color.danger') : $r('app.color.text_primary')])
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor(danger ? $r('app.color.danger') : $r('app.color.text_secondary'))
    }.id(compId).layoutWeight(1).height(56).justifyContent(FlexAlign.Center).enabled(!this.locked())
    .opacity(this.locked() ? 0.4 : 1)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .onClick(action)
  }

  @Builder
  backupMenu() {
    Menu() {
      MenuItem({ content: t('导出修改前备份') }).id('workspace-export-backup')
        .enabled(!this.locked()).onClick(() => this.exportBaseline())
      MenuItem({ content: t('恢复原版') }).id('workspace-restore')
        .enabled(!this.locked() && this.previewError.length === 0).onClick(() => this.confirmRestore())
    }
  }

  @Builder
  preview() {
    Column() {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_primary')])
        }.fontFamily(this.appearance.fontFamily).width(44).height(44).backgroundColor(Color.Transparent).accessibilityText(t("返回")).onClick(() => this.closePreview())
        Column({ space: 1 }) {
          Text(this.fileName(this.selected)).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          Text(this.editing ? (this.dirty() ? t("编辑中 · 未保存") : t("编辑中")) : this.embedded ? this.workspaceTitle : this.directory || t("工作区")).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1)
            .fontColor(this.dirty() ? this.appearance.accent : $r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.editing) {
          Button(this.busy ? t("保存中…") : t("保存")).fontFamily(this.appearance.fontFamily).id('workspace-edit-save').attributeModifier(Btn.primarySmall)
            .enabled(!this.locked()).onClick(() => this.save())
        } else if (this.imagePath.length === 0 && this.previewError.length === 0 && !isDocumentPath(this.selected) && !this.selected.startsWith('attachments/')) {
          Button(t("编辑")).fontFamily(this.appearance.fontFamily).id('workspace-edit-save').attributeModifier(Btn.tonalSmall).enabled(!this.locked())
            .onClick(() => { this.editing = true; })
        }
        if (!this.editing && this.baseline?.existed) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(22).fontColor([$r('app.color.text_primary')])
          }.fontFamily(this.appearance.fontFamily).id('workspace-backup-menu').width(40).height(40)
            .backgroundColor(Color.Transparent).accessibilityText(t('更多操作')).enabled(!this.locked())
            .bindMenu(this.backupMenu, { systemMaterial: this.appearance.surface, mask: false })
        }
        if (this.embedded && !this.tabbed) {
          IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭文件'), compId: 'close-workbench-file-preview',
            disabled: this.busy, onTap: () => this.requestClose() })
        }
      }.width('100%').height(56).padding({ left: 4, right: Space.page })
      if (this.previewError.length > 0) {
        Banner({ text: this.previewError }).padding({ left: Space.page, right: Space.page })
      }
      if (this.editing) {
        TextArea({ text: this.content, placeholder: t("开始输入…") }).fontFamily(this.appearance.fontFamily).id('workspace-content')
          .fontSize(15).lineHeight(24).layoutWeight(1).width('100%').maxLength(32000).defaultFocus(true)
          .backgroundColor(Color.Transparent).borderRadius(0).padding({ left: Space.page, right: Space.page, top: Space.sm })
          .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_tertiary'))
          .onChange((value) => { this.content = value; })
      } else if (this.imagePath.length > 0) {
        Image('file://' + this.imagePath).width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
      } else {
        Scroll() {
          Column() {
            if (this.previewError.length === 0 && this.content.length === 0) {
              EmptyState({ icon: $r('sys.symbol.doc_text'), title: t("空文件"), caption: t("点右上角“编辑”开始写内容。") })
            } else if (this.csv.length > 0) {
              DataTable({ header: this.csv[0], rows: this.csv.slice(1), maxHeight: 4000 })
            } else if (MARKDOWN_FILE.test(this.selected)) {
              MarkdownView({ content: this.content, fontSize: 15 })
            } else {
              Text(this.content).fontSize(13).lineHeight(21).fontFamily('monospace').width('100%')
                .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
                .onTextSelectionChange((start, end) => { this.selectedStart = start; this.selection = this.content.slice(start, end); })
            }
          }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto).align(Alignment.Top).edgeEffect(EdgeEffect.Spring)
      }
      if (!this.editing) {
        Row() {
          if (!this.imagePath && !this.previewError) {
            this.toolbarButton($r('sys.symbol.quote'), t("引用"), 'workspace-reference', false, () => this.reference())
          }
          this.toolbarButton($r('sys.symbol.share'), t("分享"), 'workspace-share', false, () => this.fileAction('share', this.selected))
          this.toolbarButton($r('sys.symbol.square_and_arrow_down'), t("导出"), 'workspace-export', false,
            () => this.fileAction('export', this.selected))
          this.toolbarButton($r('sys.symbol.trash'), t("删除"), 'workspace-delete', true, () => this.confirmDelete(this.selected))
        }.width('100%').padding({ left: Space.page, right: Space.page })
        .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
      }
    }.width('100%').height('100%').backgroundColor(this.embedded ? $r('app.color.surface') : $r('app.color.page_background'))
    .padding({ top: this.embedded ? 0 : this.insetTop, bottom: this.editing ? 0 : this.insetBottom })
  }

  @Builder
  listing() {
      Column() {
        if (this.directory) {
          this.breadcrumbs()
        }
        if (this.error.length > 0) {
          Banner({ text: this.error, actionLabel: t("关闭"), onAction: () => { this.error = ''; } })
            .padding({ left: Space.page, right: Space.page, bottom: Space.sm })
        }
        Refresh({ refreshing: $$this.refreshing }) {
          List() {
            if (this.entries.length === 0) {
              ListItem() {
                EmptyState({ icon: $r('sys.symbol.folder'), title: this.directory ? t("文件夹是空的") : t("这里还没有文件"),
                  caption: t("导入资料或新建笔记；助手在对话中写入的文件也会出现在这里。") })
              }
            }
            ForEach(this.entries, (entry: WorkspaceEntry) => {
              ListItem() {
                if (entry.kind === 'file') {
                  SwipeRow({ rowKey: this.join(entry.name), label: entry.name, radius: 0,
                    activeRow: this.swipeRow, disabled: this.locked(), onOpen: (key: string) => { this.swipeRow = key; },
                    onShare: () => this.fileAction('share', this.join(entry.name)),
                    onExport: () => this.fileAction('export', this.join(entry.name)),
                    onDelete: () => this.confirmDelete(this.join(entry.name)) }) {
                    this.entryRow(entry)
                  }
                } else {
                  this.entryRow(entry)
                }
              }
            }, (entry: WorkspaceEntry) => this.directory + '/' + entry.name)
            if (this.truncated) {
              ListItem() {
                Text(t("仅显示前 200 项")).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).width('100%')
                  .textAlign(TextAlign.Center).padding(Space.md)
              }
            }
          }.width('100%').height('100%')
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 68, endMargin: 0 })
          .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).contentEndOffset(Space.lg)
        }.layoutWeight(1).onRefreshing(() => { this.refresh(); })
        BottomBar() {
          Row({ space: Space.md }) {
            Button(this.busy ? t("处理中…") : t("导入文件")).fontFamily(this.appearance.fontFamily).id('workspace-import').attributeModifier(Btn.tonal).height(48).layoutWeight(1)
              .enabled(!this.locked()).onClick(() => this.importFiles())
            Button(t("新建笔记")).fontFamily(this.appearance.fontFamily).id('workspace-new').attributeModifier(Btn.primary).layoutWeight(1)
              .enabled(!this.locked()).onClick(() => this.newNote())
          }.width('100%')
        }
      }.width('100%').height('100%')

  }

  build() {
    if (this.embedded) {
      Stack() {
      Column() {
        if (!this.tabbed) {
          Row() {
            Text(this.workspaceTitle).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).fontColor($r('app.color.text_primary'))
            IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭文件'), compId: 'close-workbench-files',
              disabled: this.busy, onTap: () => this.requestClose() })
          }.height(56).width('100%').padding({ left: 16, right: 6 })
            .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
        }
        Column() { this.listing() }.layoutWeight(1).width('100%')
      }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
        .enabled(!this.previewing && !this.previewPresent)
        .accessibilityLevel(this.previewing || this.previewPresent ? 'no-hide-descendants' : 'auto')
      Stack() {
      AnimatedPage({ visible: this.previewing,
        onPresenceChanged: (present: boolean) => { this.previewPresent = present; } }) { this.preview() }
      }.width('100%').height('100%').hitTestBehavior(this.previewing ? HitTestMode.Default : HitTestMode.None)
      }.width('100%').height('100%')
    } else {
    NavDestination() {
      Column() { this.listing() }.width('100%').height('100%')
      .bindContentCover($$this.previewing, this.preview(), {
        modalTransition: ModalTransition.DEFAULT, backgroundColor: $r('app.color.page_background'),
        onWillDismiss: (action: DismissContentCoverAction) => { if (this.dirty()) { this.closePreview(); } else { action.dismiss(); } }
      })
    }
    .title(this.crumbs().length > 0 ? this.crumbs()[this.crumbs().length - 1] : this.workspaceTitle, { systemMaterial: this.appearance.control })
    .backgroundColor($r('app.color.page_background'))
    // Back goes up one folder before leaving the page, matching system file managers.
    .onBackPressed(() => {
      if (!this.directory) { return false; }
      this.go(this.crumbs().slice(0, -1).join('/')); return true;
    })
    }
  }
}
