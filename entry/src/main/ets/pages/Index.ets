import { t } from '../model/I18n';
import { ProductivityPanel } from '../views/ProductivityPanel';
import { ModelSettingsPanel } from '../views/AssistantPanel';
import { BackupPanel } from '../views/BackupPanel';
import { UsagePanel } from '../views/UsagePanel';
import { BranchesPanel } from '../views/BranchesPanel';
import { WorkspacePanel } from '../views/WorkspacePanel';
import { ToolApproval } from '../services/ToolApproval';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { KeyboardAvoidMode, SymbolGlyphModifier } from '@kit.ArkUI';
import { Attachment } from '../model/Productivity';
import { writeBytes } from '../services/Attachments';
import { ShareInbox, exportFile, shareFile } from '../services/NativeActions';
import { ChatViewModel, MessageViewModel } from '../viewmodel/ChatViewModel';
import { ChatPanel } from '../views/ChatPanel';
import { SettingsPanel, UserDocumentPanel } from '../views/SettingsPanel';
import { ThreadList } from '../views/ThreadList';
import { ProviderEditorPanel } from '../views/ProviderEditorPanel';
import { ModelPickerPanel } from '../views/ModelPickerPanel';
import { SkillsPanel } from '../views/SkillsPanel';
import { SkillEditorPanel } from '../views/SkillEditorPanel';
import { SessionService } from '../services/SessionService';
import { createNativeSessionService } from '../services/NativeSessionService';
import { Btn, Motion, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';

const DRAWER_MAX_WIDTH: number = 340;

@Entry
@Component
struct Index {
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @State private app: ChatViewModel = new ChatViewModel();
  @State private drawerOpen: boolean = false;
  @State private chatVisible: boolean = true;
  @State private drawerReveal: number = 0;
  @State private drawerDragging: boolean = false;
  @State private drawerWidth: number = DRAWER_MAX_WIDTH;
  private drawerDragStart: number = 0;
  private paths: NavPathStack = new NavPathStack();
  private session?: SessionService;
  @State private approval: ToolApproval = new ToolApproval();
  private receiving: boolean = false;

  onPageShow(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!this.session) {
      this.session = createNativeSessionService(context.filesDir, context.getApplicationContext().filesDir, this.approval);
      this.session.subscribe((event) => {
        if (event.state.ready && event.state.phase === 'idle' && !event.state.saveError && ShareInbox.peek()) { this.receiveShare(); }
      });
    }
    this.app.initialize(this.session).then(() => { ShareInbox.subscribe(() => this.receiveShare()); });
  }

  private async receiveShare(): Promise<void> {
    if (this.receiving || !this.session || !this.app.ready) { return; }
    this.receiving = true;
    try {
      await this.session.waitForIdle();
      if (!this.session.canMutate) { return; }
      let input = ShareInbox.peek();
      while (input) {
        if (input.error) { this.app.error = input.error; }
        else if (await this.app.newThread()) {
          this.app.setDraft(input.text || t("请分析分享的附件。"));
          if (!await this.app.setAttachments(input.attachments)) { return; }
          await this.app.flushDraft(); this.paths.clear();
          if (this.app.saveError) { return; }
        } else { return; }
        ShareInbox.take(); input = ShareInbox.peek();
      }
    } finally { this.receiving = false; }
  }

  onBackPress(): boolean {
    if (this.drawerOpen || this.drawerDragging) {
      this.setDrawer(false);
      return true;
    }
    return false;
  }

  aboutToDisappear(): void {
    this.app.stop();
    this.app.flushDraft();
    this.app.providerEditor.apiKey = '';
  }

  private setDrawer(open: boolean): void {
    this.getUIContext().getFocusController().clearFocus();
    this.drawerDragging = false;
    this.drawerOpen = open;
    this.getUIContext().animateTo({ duration: Motion.drawer, curve: Motion.drawerCurve }, () => {
      this.drawerReveal = open ? 1 : 0;
    });
  }

  private startDrawerDrag(event: GestureEvent, fromChat: boolean = false): void {
    if (!this.app.ready || (fromChat && (this.drawerOpen || event.offsetX <= 0 ||
      event.offsetX <= Math.abs(event.offsetY) * 1.5))) { return; }
    this.getUIContext().getFocusController().clearFocus();
    this.drawerDragStart = this.drawerReveal;
    this.drawerDragging = true;
    this.updateDrawerDrag(event);
  }

  private updateDrawerDrag(event: GestureEvent): void {
    if (!this.drawerDragging) { return; }
    // No animation during the gesture: pausing or reversing the finger immediately moves the drawer.
    this.drawerReveal = Math.max(0, Math.min(1, this.drawerDragStart + event.offsetX / this.drawerWidth));
  }

  private endDrawerDrag(event: GestureEvent): void {
    if (!this.drawerDragging) { return; }
    this.updateDrawerDrag(event);
    // A deliberate flick follows its direction; a slow release settles at the nearest edge.
    const open = Math.abs(event.velocityX) >= 600 ? event.velocityX > 0 : this.drawerReveal >= 0.5;
    this.setDrawer(open);
  }

  private cancelDrawerDrag(): void {
    if (this.drawerDragging) { this.setDrawer(this.drawerOpen); }
  }

  private openSettings(): void {
    this.app.openSettings();
    this.paths.pushPath({ name: 'settings' });
  }

  private openFiles(): void {
    this.getUIContext().getFocusController().clearFocus();
    this.paths.pushPath({ name: 'files' });
  }

  private openTools(tab: string): void {
    this.getUIContext().getFocusController().clearFocus();
    this.paths.pushPath({ name: 'productivity', param: tab });
  }

  private async fork(): Promise<void> {
    if (await this.app.forkThread()) {
      this.getUIContext().getPromptAction().showToast({ message: t("已切换到新分支，原对话保留在列表中") });
    }
  }

  private async exportChat(share: boolean): Promise<void> {
    const thread = this.app.active;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const text = '# ' + thread.title + '\n\n' + thread.messages.map((item: MessageViewModel) =>
        '## ' + (item.role === 'user' ? t("用户") : 'Tinybot') + '\n\n' + item.content +
        (item.attachments.length ? t("\n\n附件：") + item.attachments.map((file: Attachment) => file.name).join('、') : '')).join('\n\n');
      const path = context.cacheDir + '/conversation-' + util.generateRandomUUID() + '.md';
      await writeBytes(path, new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer);
      const name = (thread.title.replace(/[\\/:*?"<>|\s]+/g, '_').slice(0, 40) || t("Tinybot对话")) + '.md';
      if (share) { await shareFile(context, path, name); } else { await exportFile(context, path, name); }
    } catch (error) { this.app.error = (error as Error).message; }
  }

  // Conversation-level actions live in the header; the composer "+" sheet holds per-message inputs.
  @Builder
  moreMenu() {
    Menu() {
      MenuItemGroup({ header: t("本对话") }) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder')), content: t("工作区文件") })
          .enabled(!this.app.busy).onClick(() => this.openFiles())
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.rectangle_stack')), content: t("分支关系") })
          .enabled(!this.app.busy).onClick(() => this.paths.pushPath({ name: 'branches' }))
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.split')), content: t("创建分支") })
          .enabled(!this.app.busy && this.app.saveError.length === 0 && this.app.active.messages.length > 0)
          .onClick(() => this.fork())
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share')), content: t("分享对话") })
          .enabled(this.app.active.messages.length > 0).onClick(() => this.exportChat(true))
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_arrow_down')), content: t("导出为 Markdown") })
          .enabled(this.app.active.messages.length > 0).onClick(() => this.exportChat(false))
      }
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')), content: t('设置') })
        .onClick(() => this.openSettings())
    }
  }

  @Builder
  destination(name: string, param: Object) {
    if (name === 'branches') {
      NavDestination() { BranchesPanel({ app: this.app, onSelected: () => this.paths.clear() }) }.title(t("会话分支")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'model-settings') {
      NavDestination() { ModelSettingsPanel({ app: this.app }) }.title(t('模型分工与能力')).backgroundColor($r('app.color.page_background'))
    } else if (name === 'backup') {
      NavDestination() { BackupPanel({ app: this.app }) }.title(t('备份与恢复')).backgroundColor($r('app.color.page_background'))
    } else if (name === 'usage') {
      NavDestination() { UsagePanel({ app: this.app }) }.title(t('Token 用量')).backgroundColor($r('app.color.page_background'))
    } else if (name === 'productivity') {
      NavDestination() { ProductivityPanel({ app: this.app, tab: (param as string) || 'memory', onUse: () => { this.paths.clear(); } }) }
        .title(t("记忆与工具")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'files') {
      WorkspacePanel({ app: this.app })
    } else if (name === 'settings') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings,
          onUsage: () => { this.paths.pushPath({ name: 'usage' }); },
          onModels: () => { this.paths.pushPath({ name: 'model-settings' }); },
          onBackup: () => { this.paths.pushPath({ name: 'backup' }); },
          onTools: (tab: string) => this.openTools(tab),
          onSkills: () => { this.paths.pushPath({ name: 'skills' }); },
          onUserDocument: () => { this.paths.pushPath({ name: 'user-document' }); },
          onEditProvider: (id: string, preset: string) => {
            if (this.app.beginProvider(preset, id)) { this.paths.pushPath({ name: 'provider' }); }
          } })
      }.title(t("设置")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'user-document') {
      NavDestination() {
        UserDocumentPanel({ app: this.app, settings: this.app.settings, onSaved: () => { this.paths.pop(); } })
      }.title(t('用户文档（USER.md）')).backgroundColor($r('app.color.page_background'))
        .onHidden(() => { this.app.settings.userDocument = this.app.config.userDocument || ''; })
    } else if (name === 'skills') {
      NavDestination() {
        SkillsPanel({ app: this.app, onEdit: (skill: string) => {
          this.app.beginSkill(skill);
          this.paths.pushPath({ name: 'skill-editor' });
        }, onUse: () => { this.paths.clear(); } })
      }.title('Skills').backgroundColor($r('app.color.page_background'))
    } else if (name === 'skill-editor') {
      NavDestination() {
        SkillEditorPanel({ app: this.app, editor: this.app.skillEditor, onSaved: () => { this.paths.pop(); } })
      }.title(this.app.skillEditor.originalName.length > 0 ? t("编辑 Skill") : t("添加 Skill")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'provider') {
      NavDestination() {
        ProviderEditorPanel({ app: this.app, editor: this.app.providerEditor, onSaved: () => { this.paths.pop(); } })
      }.title(this.app.providerEditor.id.length > 0 ? t("编辑服务") : t("添加服务")).backgroundColor($r('app.color.page_background'))
        .onBackPressed(() => {
          if (this.app.busy) { return true; }
          if (!this.app.providerEditor.hasChanges) { return false; }
          this.getUIContext().showAlertDialog({ title: t('放弃未保存的修改？'), message: t('离开后，本次对服务配置的修改不会保存。'),
            primaryButton: { value: t('继续编辑'), action: () => {} },
            secondaryButton: { value: t('放弃修改'), fontColor: $r('app.color.danger'), action: () => { this.paths.pop(); } } });
          return true;
        })
        .onHidden(() => { this.app.providerEditor.apiKey = ''; })
    } else if (name === 'models') {
      NavDestination() {
        ModelPickerPanel({ app: this.app, onSelected: () => { this.paths.pop(); }, onSettings: () => this.openSettings() })
      }.title(t("选择模型")).backgroundColor($r('app.color.page_background'))
    }
  }

  @Builder
  header() {
    Row({ space: 4 }) {
      IconButton({ icon: $r('sys.symbol.line_3_horizontal'), label: t("对话列表"), compId: 'open-history',
        disabled: !this.app.ready, onTap: () => this.setDrawer(true) })
      Column({ space: 1 }) {
        Text(this.app.ready ? this.app.active.displayTitle : 'Tinybot').fontSize(16).fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Row({ space: 2 }) {
          if (this.app.ready && this.app.active.teamEnabled) {
            SymbolGlyph($r('sys.symbol.person_2')).fontSize(12).fontColor([$r('app.color.accent')]).margin({ right: 2 })
              .accessibilityText(t("团队模式已开启"))
          }
          Text(this.app.ready ? this.app.currentModelLabel : t("你的随身 AI 助手")).fontSize(12).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
            .fontColor(this.app.ready && !this.app.configured ? $r('app.color.danger') : $r('app.color.text_secondary'))
          if (this.app.ready) {
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          }
        }.justifyContent(FlexAlign.Center).constraintSize({ maxWidth: '100%' })
      }
      .id('open-model-picker').layoutWeight(1).padding({ top: 4, bottom: 4 }).borderRadius(12)
      .accessibilityText(t("切换模型：") + this.app.currentModelLabel)
      .enabled(this.app.ready && !this.app.busy && !this.app.active.archived)
      .onClick(() => { this.paths.pushPath({ name: 'models' }); })
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(20).fontColor([$r('app.color.text_primary')])
      }.id('chat-more').width(40).height(44).backgroundColor(Color.Transparent).accessibilityText(t("更多操作"))
      .enabled(this.app.ready).bindMenu(this.moreMenu)
      IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t("新建对话"), compId: 'new-chat',
        disabled: !this.app.ready || this.app.busy || this.app.saveError.length > 0,
        onTap: () => { this.app.newThread(); } })
    }.width('100%').height(56).padding({ left: 6, right: 6 })
  }

  @Builder
  drawer() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width('100%').height('100%').backgroundColor($r('app.color.scrim'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .opacity(this.drawerReveal)
        .onClick(() => this.setDrawer(false))
      Stack() {
        Column().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
          .borderRadius({ topRight: 20, bottomRight: 20 })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        ThreadList({ app: this.app, onSelected: () => this.setDrawer(false), onSettings: () => {
          this.setDrawer(false);
          this.openSettings();
        } })
      }
      .width('84%').constraintSize({ maxWidth: DRAWER_MAX_WIDTH }).height('100%')
      .id('history-drawer')
      .translate({ x: (this.drawerReveal - 1) * this.drawerWidth })
      .onAreaChange((_old: Area, next: Area) => { this.drawerWidth = Math.max(1, next.width as number); })
    }.width('100%').height('100%')
    .hitTestBehavior(this.drawerOpen || this.drawerDragging ? HitTestMode.Default : HitTestMode.None)
    .enabled(this.drawerOpen || this.drawerDragging)
    .accessibilityLevel(this.drawerOpen || this.drawerDragging ? 'auto' : 'no-hide-descendants')
    .gesture(PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Horizontal, distance: 8 })
      .onActionStart((event: GestureEvent) => this.startDrawerDrag(event))
      .onActionUpdate((event: GestureEvent) => this.updateDrawerDrag(event))
      .onActionEnd((event: GestureEvent) => this.endDrawerDrag(event))
      .onActionCancel(() => this.cancelDrawerDrag()))
  }

  build() {
    Column() {
      ForEach([this.locale], (_locale: string) => {
    Navigation(this.paths) {
      Stack() {
        Column().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        Column() {
          this.header()
          if (this.app.ready) {
            ChatPanel({ app: this.app, thread: this.app.active, approval: this.approval, onSettings: () => this.openSettings(),
                activeThreadId: this.app.active.id, speechEnabled: this.chatVisible && !this.drawerOpen && !this.drawerDragging,
                onHistoryDragStart: (event: GestureEvent) => this.startDrawerDrag(event, true),
                onHistoryDragUpdate: (event: GestureEvent) => this.updateDrawerDrag(event),
                onHistoryDragEnd: (event: GestureEvent) => this.endDrawerDrag(event),
                onHistoryDragCancel: () => this.cancelDrawerDrag(),
                onFiles: () => this.openFiles(), onTools: (tab: string) => this.openTools(tab) })
              .layoutWeight(1)
          } else {
            Column({ space: Space.lg }) {
              if (this.app.loading) {
                LoadingProgress().width(32).height(32).color($r('app.color.accent'))
                Text(t("正在打开本地会话…")).fontColor($r('app.color.text_secondary'))
              } else {
                Text(this.app.error).fontColor($r('app.color.danger')).textAlign(TextAlign.Center)
                Button(t("重试读取")).attributeModifier(Btn.tonal).onClick(() => this.onPageShow())
              }
            }.padding(Space.xl).layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
          }
        }.width('100%').height('100%')
        // The page drifts aside a little under the drawer, giving the layers depth.
        .translate({ x: this.drawerReveal * 28 })
        // Keep the measured drawer mounted so the first drag frame needs no enter transition.
        if (this.app.ready) {
          this.drawer()
        }
      }.width('100%').height('100%')
    }
    .backgroundColor($r('app.color.page_background'))
    .hideTitleBar(true).hideToolBar(true).mode(NavigationMode.Stack)
    .onNavBarStateChange((visible: boolean) => { this.chatVisible = visible; })
    .navDestination(this.destination).width('100%').height('100%')
      }, (locale: string) => locale)
    }.width('100%').height('100%')
  }
}
