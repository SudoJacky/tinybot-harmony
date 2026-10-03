import { t } from '../model/I18n';
import { SwipeRow } from '../common/SwipeRow';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { NativeWorkspaceFiles } from '../services/NativeWorkspaceFiles';
import { Cancellation } from '../services/Cancellation';
import { readSkillImport } from '../services/SkillImport';
import { Attachments } from '../services/Attachments';
import { exportFile, shareFile } from '../services/NativeActions';
import { MarkdownView } from './MarkdownView';
import { DataTable } from './DataTable';
import { parseDelimited, lineDiff } from '../model/RichArtifacts';
import { FileBaseline } from '../services/NativeWorkspaceFiles';
import { Btn, Font, Radius, Space, systemInsets } from '../common/Theme';
import { Banner, BottomBar, EmptyState } from '../common/Widgets';

interface WorkspaceEntry { name: string; kind: string; }
interface WorkspaceListing { entries: WorkspaceEntry[]; truncated: boolean; }
interface WorkspaceText { content: string; }

const IMAGE_FILE: RegExp = /\.(png|jpe?g|webp|gif|bmp)$/i;
const MARKDOWN_FILE: RegExp = /\.(md|markdown)$/i;

function pad(value: number): string { return value < 10 ? '0' + value : value.toString(); }

@Component
export struct WorkspacePanel {
  @ObjectLink app: ChatViewModel;
  @State private directory: string = '';
  @State private swipeRow: string = '';
  @State private entries: WorkspaceEntry[] = [];
  @State private selected: string = '';
  @State private content: string = '';
  @State private original: string = '';
  @State private imagePath: string = '';
  @State private previewError: string = '';
  @State private previewing: boolean = false;
  @State private editing: boolean = false;
  @State private busy: boolean = false;
  @State private refreshing: boolean = false;
  @State private error: string = '';
  @State private baseline: FileBaseline | undefined = undefined;
  @State private reviewing: boolean = false;
  @State private csv: string[][] = [];
  @State private selection: string = '';
  @State private selectedStart: number = 0;
  @State private truncated: boolean = false;
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  private files?: NativeWorkspaceFiles;
  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.files = new NativeWorkspaceFiles(new WorkspaceStore(context.getApplicationContext().filesDir).pathFor(this.app.active.id));
    this.refresh();
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetTop = insets[0]; this.insetBottom = insets[1]; });
  }

  private locked(): boolean { return this.busy || this.app.busy; }
  private join(name: string): string { return (this.directory ? this.directory + '/' : '') + name; }
  private fileName(path: string): string { return path.split('/').pop() || t("文件.txt"); }
  private toast(message: string): void { this.getUIContext().getPromptAction().showToast({ message: message }); }
  private crumbs(): string[] { return this.directory ? this.directory.split('/') : []; }
  private dirty(): boolean { return this.editing && this.content !== this.original; }

  private async refresh(): Promise<void> {
    if (!this.files) { return; }
    try {
      const list = JSON.parse(await this.files.list(this.directory || '.', new Cancellation())) as WorkspaceListing;
      // Folders first, then files, each alphabetical.
      this.entries = list.entries.sort((a, b) => (a.kind === 'directory' ? 0 : 1) - (b.kind === 'directory' ? 0 : 1) || a.name.localeCompare(b.name));
      this.truncated = list.truncated; this.error = '';
    } catch (error) { this.error = (error as Error).message; }
    finally { this.refreshing = false; }
  }
  private go(directory: string): void { this.directory = directory; this.refresh(); }

  private async open(entry: WorkspaceEntry): Promise<void> {
    if (!this.files || this.busy || entry.kind === 'symlink') { return; }
    const path = this.join(entry.name);
    if (entry.kind === 'directory') { this.go(path); return; }
    this.selected = path; this.editing = false; this.content = ''; this.original = ''; this.imagePath = ''; this.previewError = '';
    this.reviewing = false; this.baseline = undefined; this.csv = []; this.selection = '';
    try {
      if (IMAGE_FILE.test(entry.name)) { this.imagePath = await this.files.checkedPath(path); }
      else { this.content = (JSON.parse(await this.files.read(path, new Cancellation())) as WorkspaceText).content; this.original = this.content; }
      this.baseline = await this.files.baseline(path);
      if (/\.(csv|tsv)$/i.test(path)) { this.csv = parseDelimited(this.content, /\.tsv$/i.test(path) ? '\t' : ','); }
    } catch (error) { this.previewError = t("无法预览：") + (error as Error).message; }
    this.previewing = true;
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
    try {
      const uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 5, fileSuffixFilters: [t("资料|.txt,.md,.csv,.tsv,.json,.log,.pdf,.docx,.xlsx,.pptx")] });
      if (!uris.length) { return; }
      this.busy = true; let count = 0;
      for (const uri of uris) {
        const document = /\.(pdf|docx|xlsx|pptx)(?:\?|$)/i.test(uri);
        const text = document ? (await Attachments.import(uri, false)).text || '' : await readSkillImport(uri);
        let name = uri.slice(uri.lastIndexOf('/') + 1).split('?')[0];
        try { name = decodeURIComponent(name); } catch (_) { /* Keep literal URI name. */ }
        name = name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').slice(-80) || t("导入-") + Date.now() + '.txt';
        if (document) { name += '.txt'; }
        await this.files.write(this.join(this.uniqueName(name)), text, new Cancellation());
        count++; await this.refresh();
      }
      this.toast(t("已导入 ") + count + t(" 个文件"));
    } catch (error) { this.error = (error as Error).message; }
    finally { this.busy = false; await this.refresh(); }
  }

  private async newNote(): Promise<void> {
    if (!this.files || this.locked()) { return; }
    const now = new Date();
    const path = this.join(this.uniqueName(t("笔记-") + (now.getMonth() + 1) + pad(now.getDate()) + '-' + pad(now.getHours()) + pad(now.getMinutes()) + '.md'));
    this.busy = true;
    try {
      await this.files.write(path, '', new Cancellation()); await this.refresh();
      this.selected = path; this.content = ''; this.original = ''; this.imagePath = ''; this.previewError = '';
      this.editing = true; this.previewing = true;
    } catch (error) { this.error = (error as Error).message; }
    finally { this.busy = false; }
  }

  private async save(): Promise<void> {
    if (!this.files || this.locked()) { return; }
    this.busy = true;
    try {
      await this.files.write(this.selected, this.content, new Cancellation());
      this.baseline = await this.files.baseline(this.selected);
      this.original = this.content; this.editing = false; this.toast(t("已保存")); await this.refresh();
    } catch (error) { this.previewError = (error as Error).message; }
    finally { this.busy = false; }
  }

  private async reviewAction(restore: boolean): Promise<void> {
    if (!this.files || this.locked()) { return; }
    this.busy = true;
    try {
      if (restore) { await this.files.restore(this.selected, this.original); }
      else { await this.files.accept(this.selected); }
      this.previewing = false; await this.refresh();
    } catch (error) { this.previewError = (error as Error).message; }
    finally { this.busy = false; }
  }
  private reference(): void {
    const text = this.selection || this.content.slice(0, 4000);
    const line = this.content.slice(0, this.selectedStart).split('\n').length;
    this.app.setDraft(this.app.active.draft + t("\n\n引用文件 ") + this.selected + t("，第 ") + line + t(" 行附近：\n") + text.slice(0, 4000) + t("\n修改要求："));
    this.previewing = false; this.toast(t("引用已加入当前对话草稿"));
  }

  private async fileAction(kind: string, path: string): Promise<void> {
    if (!this.files || this.locked()) { return; }
    this.busy = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const absolute = await this.files.checkedPath(path);
      if (kind === 'export') { await exportFile(context, absolute, this.fileName(path)); }
      if (kind === 'share') { await shareFile(context, absolute, this.fileName(path)); }
      if (kind === 'delete') {
        await fs.unlink(absolute);
        if (this.selected === path) { this.previewing = false; this.selected = ''; }
        this.toast(t("已删除"));
      }
    } catch (error) { if (this.previewing) { this.previewError = (error as Error).message; } else { this.error = (error as Error).message; } }
    finally { this.busy = false; await this.refresh(); }
  }

  private confirmDelete(path: string): void {
    this.getUIContext().showAlertDialog({ title: t("删除文件？"), message: this.fileName(path) + t("\n删除后无法恢复。"),
      primaryButton: { value: t("取消"), action: () => {} },
      secondaryButton: { value: t("删除"), fontColor: $r('app.color.danger'), action: () => this.fileAction('delete', path) } });
  }

  private closePreview(): void {
    if (!this.dirty()) { this.previewing = false; this.editing = false; return; }
    this.getUIContext().showAlertDialog({ title: t("放弃未保存的修改？"), message: this.fileName(this.selected),
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
          .fontColor([entry.kind === 'directory' ? $r('app.color.accent') : $r('app.color.text_secondary')])
      }.width(40).height(40).borderRadius(Radius.sm).justifyContent(FlexAlign.Center)
      .backgroundColor(entry.kind === 'directory' ? $r('app.color.accent_container') : $r('app.color.surface_variant'))
      Column({ space: 2 }) {
        Text(entry.name).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'))
        Text(this.kindLabel(entry)).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
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
        Text(t("工作区")).fontSize(14).padding({ left: 8, right: 8 }).height(32).borderRadius(16)
          .fontColor(this.directory ? $r('app.color.accent') : $r('app.color.text_primary'))
          .fontWeight(this.directory ? FontWeight.Normal : FontWeight.Medium)
          .onClick(() => { if (this.directory) { this.go(''); } })
        ForEach(this.crumbs(), (part: string, index: number) => {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.text_tertiary')])
          Text(part).fontSize(14).padding({ left: 8, right: 8 }).height(32).borderRadius(16).maxLines(1)
            .fontColor(index === this.crumbs().length - 1 ? $r('app.color.text_primary') : $r('app.color.accent'))
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
      Text(label).fontSize(11).fontColor(danger ? $r('app.color.danger') : $r('app.color.text_secondary'))
    }.id(compId).layoutWeight(1).height(56).justifyContent(FlexAlign.Center).enabled(!this.locked())
    .opacity(this.locked() ? 0.4 : 1)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .onClick(action)
  }

  // Changed lines on tinted rows: removals red, additions green, hunk headers muted.
  @Builder
  diffView() {
    Column() {
      ForEach(lineDiff(this.baseline?.content || '', this.content).split('\n'), (line: string) => {
        Text(line.length > 0 ? line : ' ').fontSize(12).lineHeight(19).fontFamily('monospace').width('100%')
          .padding({ left: 10, right: 10, top: 1, bottom: 1 }).copyOption(CopyOptions.LocalDevice)
          .fontColor(line.startsWith('@@') ? $r('app.color.text_tertiary') : line.startsWith('- ') ? $r('app.color.danger') : $r('app.color.text_primary'))
          .backgroundColor(line.startsWith('+ ') ? $r('app.color.accent_container') : line.startsWith('- ') ? $r('app.color.danger_container') : Color.Transparent)
      }, (line: string, index: number) => index + line)
    }.width('100%').borderRadius(Radius.sm).clip(true).border({ width: 0.5, color: $r('app.color.divider') })
  }

  // The assistant changed this file during a task: keep the change or restore the saved baseline.
  @Builder
  reviewCard() {
    Column({ space: 10 }) {
      Row({ space: Space.sm }) {
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([$r('app.color.accent')])
        Column({ space: 2 }) {
          Text(t("助手修改了这个文件")).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(this.baseline?.existed ? t("确认保留修改，或恢复到修改前的版本。") : t("这是助手新建的文件。")).fontSize(Font.caption)
            .fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.reviewing ? t("看内容") : t("看差异")).id('workspace-diff').attributeModifier(Btn.textSmall)
          .padding({ left: 10, right: 10 }).onClick(() => { this.reviewing = !this.reviewing; })
      }.width('100%')
      Row({ space: Space.sm }) {
        Button(this.baseline?.existed ? t("恢复原版") : t("删除文件")).id('workspace-restore').attributeModifier(Btn.plainSmall)
          .height(36).layoutWeight(1).enabled(!this.locked()).onClick(() => {
            this.getUIContext().showAlertDialog({ title: t("恢复修改前版本？"), message: this.baseline?.existed ? t("当前内容将被保存基线替换。") : t("此文件是新建文件，恢复会删除它。"),
              primaryButton: { value: t("取消"), action: () => {} }, secondaryButton: { value: t("恢复"), fontColor: $r('app.color.danger'), action: () => this.reviewAction(true) } });
          })
        Button(t("保留修改")).id('workspace-accept').attributeModifier(Btn.primarySmall).height(36).layoutWeight(1)
          .enabled(!this.locked()).onClick(() => this.reviewAction(false))
      }.width('100%')
    }.padding(Space.md).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.accent_container') })
    .margin({ left: Space.page, right: Space.page, bottom: Space.sm })
  }

  @Builder
  preview() {
    Column() {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText(t("返回")).onClick(() => this.closePreview())
        Column({ space: 1 }) {
          Text(this.fileName(this.selected)).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          Text(this.editing ? (this.dirty() ? t("编辑中 · 未保存") : t("编辑中")) : this.directory || t("工作区")).fontSize(Font.caption).maxLines(1)
            .fontColor(this.dirty() ? $r('app.color.accent') : $r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.editing) {
          Button(this.busy ? t("保存中…") : t("保存")).id('workspace-edit-save').attributeModifier(Btn.primarySmall)
            .enabled(!this.locked()).onClick(() => this.save())
        } else if (this.imagePath.length === 0 && this.previewError.length === 0) {
          Button(t("编辑")).id('workspace-edit-save').attributeModifier(Btn.tonalSmall).enabled(!this.locked())
            .onClick(() => { this.editing = true; })
        }
      }.width('100%').height(56).padding({ left: 4, right: Space.page })
      if (this.previewError.length > 0) {
        Banner({ text: this.previewError }).padding({ left: Space.page, right: Space.page })
      }
      if (this.editing) {
        TextArea({ text: this.content, placeholder: t("开始输入…") }).id('workspace-content')
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
            } else if (this.reviewing && this.baseline) {
              this.diffView()
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
        if (this.baseline && !this.previewError) {
          this.reviewCard()
        }
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
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
    .padding({ top: this.insetTop, bottom: this.editing ? 0 : this.insetBottom })
  }

  build() {
    NavDestination() {
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
                Text(t("仅显示前 200 项")).fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).width('100%')
                  .textAlign(TextAlign.Center).padding(Space.md)
              }
            }
          }.width('100%').height('100%')
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 68, endMargin: 0 })
          .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).contentEndOffset(Space.lg)
        }.layoutWeight(1).onRefreshing(() => { this.refresh(); })
        BottomBar() {
          Row({ space: Space.md }) {
            Button(this.busy ? t("处理中…") : t("导入文件")).id('workspace-import').attributeModifier(Btn.tonal).height(48).layoutWeight(1)
              .enabled(!this.locked()).onClick(() => this.importFiles())
            Button(t("新建笔记")).id('workspace-new').attributeModifier(Btn.primary).layoutWeight(1)
              .enabled(!this.locked()).onClick(() => this.newNote())
          }.width('100%')
        }
      }.width('100%').height('100%')
      .bindContentCover($$this.previewing, this.preview(), {
        modalTransition: ModalTransition.DEFAULT, backgroundColor: $r('app.color.page_background'),
        onWillDismiss: (action: DismissContentCoverAction) => { if (this.dirty()) { this.closePreview(); } else { action.dismiss(); } }
      })
    }
    .title(this.crumbs().length > 0 ? this.crumbs()[this.crumbs().length - 1] : t("工作区文件"))
    .backgroundColor($r('app.color.page_background'))
    // Back goes up one folder before leaving the page, matching system file managers.
    .onBackPressed(() => {
      if (!this.directory) { return false; }
      this.go(this.crumbs().slice(0, -1).join('/')); return true;
    })
  }
}
