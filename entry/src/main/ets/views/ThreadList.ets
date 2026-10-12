import { AppMaterials } from '../common/AppMaterials';
import { t } from '../model/I18n';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
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
  @Prop query: string = '';
  @Prop lastBranch: boolean = false;
  @Prop activePath: boolean = false;
  @State private rowHeight: number = 64;
  @ObjectLink thread: ThreadViewModel;
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  @State private editing: boolean = false;
  @State private name: string = '';

  private locked(): boolean {
    return this.app.busy || this.app.saveError.length > 0;
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
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')), content: t("重命名") })
        .onClick(() => { this.name = this.thread.title; this.editing = true; })
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.pin')),
        content: this.thread.pinned ? t("取消置顶") : t("置顶") })
        .onClick(() => this.app.pinThread(this.thread.id))
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.archivebox')),
        content: this.thread.archived ? t("恢复对话") : t("归档") })
        .onClick(() => this.app.archiveThread(this.thread.id))
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([$r('app.color.danger')]),
        content: t("删除") }).contentFontColor($r('app.color.danger'))
        .onClick(() => {
          this.getUIContext().showAlertDialog({ systemMaterial: AppMaterials.surface,
            title: t("删除这段对话？"), message: this.thread.title + t("\n会话工作区中的文件会保留。"),
            primaryButton: { value: t("取消"), action: () => {} },
            secondaryButton: { value: t("删除"), fontColor: $r('app.color.danger'),
              action: () => { this.app.deleteThread(this.thread.id); } }
          });
        })
    }
  }

  @Builder
  renameEditor() {
    Row({ space: 4 }) {
      TextInput({ text: this.name, placeholder: t("对话名称") }).maxLength(80).layoutWeight(1).height(40)
        .fontSize(15).backgroundColor($r('app.color.surface')).defaultFocus(true)
        .onChange((value: string) => { this.name = value; })
        .onSubmit(async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.xmark'), label: t("取消"), diameter: 36, iconSize: 18,
        tint: $r('app.color.text_secondary'), onTap: () => { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.checkmark'), label: t("保存名称"), diameter: 36, iconSize: 18,
        tint: $r('app.color.accent'), disabled: this.locked(),
        onTap: async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } } })
    }.width('100%').padding({ left: Space.sm, right: 4, top: 6, bottom: 6 })
  }

  build() {
    Stack({ alignContent: Alignment.End }) {
    Column() {
      if (this.editing) {
        this.renameEditor()
      } else {
        Row({ space: Space.sm }) {
          Column({ space: 4 }) {
            Row({ space: 4 }) {
              if (this.thread.pinned) {
                SymbolGlyph($r('sys.symbol.pin_fill')).fontSize(13).fontColor([$r('app.color.accent')])
              }
              Text(this.thread.displayTitle).fontSize(15).maxLines(1).layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontWeight(this.active() ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.active() ? $r('app.color.on_accent_container') : $r('app.color.text_primary'))
            }.width('100%')
            if (this.query.trim()) { Text(this.snippet()).fontSize(12).maxLines(2).fontColor($r('app.color.accent')) }
            if (this.thread.parentThreadId) { Text('↳ ' + (this.app.threads.find((item) => item.id === this.thread.parentThreadId)?.title || t("原对话已删除"))).fontSize(11).maxLines(1).fontColor($r('app.color.text_secondary')) }
            Row({ space: 6 }) {
              Text(shortTime(this.thread.updatedAt)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
              if (this.thread.draft.length > 0) {
                Text(t("草稿")).fontSize(11).fontColor($r('app.color.danger'))
              }
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.width(32).height(32).backgroundColor(Color.Transparent).accessibilityText(t("对话管理"))
          .enabled(!this.locked()).bindMenu(this.actions, {
            systemMaterial: AppMaterials.surface, mask: false })
        }
        .width('100%').padding({ left: Space.md, right: 4, top: 10, bottom: 10 })
        .onClick(async () => {
          if (this.locked()) { return; }
          if (this.query.trim() ? await this.app.openMessage(this.thread.id, this.matchId(), this.query.trim()) : await this.app.selectThread(this.thread.id)) { this.onSelected(); }
        })
        .bindContextMenu(this.actions, ResponseType.LongPress, {
          systemMaterial: AppMaterials.surface, mask: false })
      }
    }
    .width('calc(100% - 28vp)').borderRadius(Radius.md)
    .backgroundColor(this.active() ? $r('app.color.accent_container') : Color.Transparent)
    .opacity(this.locked() && !this.active() ? 0.6 : 1)
    .onAreaChange((_old: Area, area: Area) => { this.rowHeight = Number(area.height); })
    Shape() {
      Path().commands(`M12 0 V${this.lastBranch ? this.rowHeight / 2 - 8 : this.rowHeight} M12 ${this.rowHeight / 2 - 8} Q12 ${this.rowHeight / 2} 20 ${this.rowHeight / 2} H28`)
        .stroke($r('app.color.divider'))
      Path().commands(this.active() ? `M12 0 V${this.rowHeight / 2 - 8} Q12 ${this.rowHeight / 2} 20 ${this.rowHeight / 2} H28` : `M12 0 V${this.rowHeight}`)
        .stroke($r('app.color.accent')).strokeDashArray([this.rowHeight + 28, this.rowHeight + 28])
        .strokeDashOffset(this.activePath ? 0 : this.rowHeight + 28)
        .animation({ duration: Motion.drawer, curve: Motion.standard })
    }.viewPort({ x: 0, y: 0, width: '28px', height: this.rowHeight + 'px' })
      .width(28).height(this.rowHeight).fill(Color.Transparent).strokeWidth('1.25px')
      .strokeLineCap(LineCapStyle.Round).position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }.id('thread-row-' + this.thread.id).width('100%')
  }
}

// Project tree; presentation grouping never changes a thread's stored project membership.
@Component
export struct ThreadList {
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  onSettings: () => void = () => {};
  onFiles: () => void = () => {};
  @State private query: string = '';
  @State private archived: boolean = false;
  @State private visibleCounts: Record<string, number> = {};
  @State private collapsedProjects: string[] = [];
  @State private projectEditing: boolean = false;
  @State private projectId: string = '';
  @State private projectName: string = '';
  @State private projectInstructions: string = '';

  private filtered(): ThreadViewModel[] {
    return this.app.filteredThreads(this.query, this.archived);
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
    this.projectEditing = true;
  }

  @Builder
  projectEditor() {
    Scroll() {
      Column({ space: Space.md }) {
        TextInput({ text: this.projectName, placeholder: t('项目名称') }).id('project-name').maxLength(80)
          .onChange((value: string) => { this.projectName = value; })
        TextArea({ text: this.projectInstructions, placeholder: t('项目说明与约定（可选）') }).id('project-instructions')
          .height(220).maxLength(16000).onChange((value: string) => { this.projectInstructions = value; })
        Text(t('项目内的会话共享文件和项目说明，各自保留对话历史。')).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
        if (this.app.error) { Banner({ text: this.app.error }) }
        Button(t('保存')).id('project-save').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.busy && !this.app.saveError && this.projectName.trim().length > 0)
          .onClick(async () => {
            const creating = !this.projectId;
            if (await this.app.saveProject(this.projectName, this.projectInstructions, this.projectId || undefined)) {
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
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder')), content: t('项目文件') })
        .onClick(async () => { if (await this.app.openProject(id)) { this.onFiles(); } })
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')), content: t('编辑项目') })
        .onClick(() => this.editProject(id))
    }
  }

  @Builder
  sectionHeader(id: string) {
    Row({ space: 2 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 7 }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12)
              .fontColor([$r('app.color.text_tertiary')])
          }.width(24).height(24)
            .rotate({ angle: this.groupOpen(id) ? 0 : -90, centerX: '50%', centerY: '50%' })
            .animation({ duration: Motion.medium, curve: Motion.standard })
          Text(this.sectionTitle(id)).fontSize(14).fontWeight(FontWeight.Medium).maxLines(1).layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor((this.app.active.projectId || '') === id ? $r('app.color.accent') : $r('app.color.text_secondary'))
          Text(String(this.sectionThreads(id).length)).fontSize(11).fontColor($r('app.color.text_tertiary'))
        }.width('100%')
      }.id('project-group-' + (id || 'ordinary')).layoutWeight(1).height(44).padding({ right: 4 })
        .backgroundColor(Color.Transparent).borderRadius(10).onClick(() => this.toggleGroup(id))
        .accessibilityText(this.sectionTitle(id) + '，' + (this.groupOpen(id) ? t('收起') : t('展开')))
      IconButton({ icon: $r('sys.symbol.plus'), label: t('新对话') + ' · ' + this.sectionTitle(id),
        compId: 'project-new-chat-' + (id || 'ordinary'), diameter: 32, iconSize: 16,
        disabled: this.app.busy || !!this.app.saveError,
        onTap: async () => { if (await this.app.newThread(id)) { this.onSelected(); } } })
      if (id) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
        }.id('project-actions-' + id).width(32).height(32).backgroundColor(Color.Transparent)
          .accessibilityText(t('编辑项目') + ' · ' + this.sectionTitle(id)).enabled(!this.app.busy && !this.app.saveError)
          .bindMenu(this.projectActions(id), { systemMaterial: AppMaterials.surface, mask: false })
      }
    }.width('100%').padding({ top: 4 }).backgroundColor($r('app.color.page_background'))
  }

  build() {
    Column({ space: Space.md }) {
      Row({ space: Space.sm }) {
        Image($r('app.media.tinybot')).width(28).height(28)
        Text('Tinybot').fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1).fontColor($r('app.color.text_primary'))
        IconButton({ icon: $r('sys.symbol.folder_badge_plus'), label: t('新建项目'), compId: 'project-create',
          disabled: this.app.busy || !!this.app.saveError, onTap: () => this.editProject() })
      }.width('100%').height(48).padding({ left: 4 })
      Button() {
        Row({ space: Space.sm }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([$r('app.color.on_accent_container')])
          Text(t("新对话")).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.on_accent_container'))
        }
      }.id('history-new-chat').attributeModifier(Btn.tonal).width('100%')
      .enabled(!this.app.busy && this.app.saveError.length === 0)
      .onClick(async () => { if (await this.app.newThread('')) { this.onSelected(); } })
      Search({ value: this.query, placeholder: t("搜索对话") }).id('search-threads').height(40)
        .backgroundColor($r('app.color.surface_variant')).placeholderColor($r('app.color.text_tertiary'))
        .onChange((value: string) => { this.query = value; this.visibleCounts = {}; })
      Segmented({ options: [t("对话"), t("已归档")], selected: this.archived ? 1 : 0,
        optionIds: ['active-threads', 'archived-threads'], controlHeight: 38, labelSize: 13,
        trackRadius: 19, thumbRadius: 16, gap: 2, thumbShadow: false,
        onSelect: (index: number) => { this.archived = index === 1; this.visibleCounts = {}; } })
      if (this.sections(this.filtered()).length === 0) {
        Column({ space: Space.sm }) {
          SymbolGlyph(this.query.trim().length > 0 ? $r('sys.symbol.magnifyingglass') : $r('sys.symbol.ellipsis_message'))
            .fontSize(32).fontColor([$r('app.color.text_tertiary')])
          Text(this.query.trim().length > 0 ? t("没有匹配的对话") : this.archived ? t("没有归档的对话") : t("还没有对话"))
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
                    ListItem() { ThreadRow({ thread: thread, app: this.app, query: this.query, onSelected: this.onSelected,
                      lastBranch: this.lastBranch(id, thread.id),
                      activePath: this.onActivePath(id, thread.id) }) }
                      .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fast, curve: Motion.standard }))
                  }, (thread: ThreadViewModel) => thread.id)
                  if (this.sectionThreads(id).length === 0) {
                    ListItem() { Text(t('还没有对话')).fontSize(12).fontColor($r('app.color.text_tertiary'))
                      .padding({ left: 32, top: 8, bottom: 16 }) }
                  }
                  if (this.sectionThreads(id).length > this.visibleCount(id)) {
                    ListItem() {
                      Button(t('加载更多对话')).id('load-more-threads-' + (id || 'ordinary')).attributeModifier(Btn.textSmall)
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
        Banner({ text: this.app.saveError, actionLabel: t("重试"), actionEnabled: !this.app.busy,
          onAction: () => { this.app.retrySave(); } })
      } else if (this.app.error.length > 0) {
        Banner({ text: this.app.error })
      }
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      Row({ space: Space.md }) {
        SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.text_secondary')])
        Text(t("设置")).fontSize(15).layoutWeight(1).fontColor($r('app.color.text_primary'))
        Text(t("{0} 个服务", [this.app.providerProfiles.length])).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
      }
      .id('open-settings').width('100%').height(48).padding({ left: Space.md, right: Space.md }).borderRadius(Radius.md)
      .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
      .onClick(() => this.onSettings())
    }
    .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
    .height('100%').width('100%').backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.projectEditing, this.projectEditor(), { title: { title: this.projectId ? t('编辑项目') : t('新建项目') },
      detents: [SheetSize.LARGE], dragBar: true, keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY })
  }
}
