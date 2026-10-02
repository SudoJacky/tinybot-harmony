import { t } from '../model/I18n';
import { ProductivityPanel } from '../views/ProductivityPanel';
import { AssistantPanel } from '../views/AssistantPanel';
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
import { SettingsPanel, SystemPromptPanel } from '../views/SettingsPanel';
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
  @State private drawerDrag: number = 0;
  @State private drawerWidth: number = DRAWER_MAX_WIDTH;
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
    if (this.drawerOpen) {
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
    if (open) { this.getUIContext().getFocusController().clearFocus(); }
    this.getUIContext().animateTo({ duration: Motion.drawer, curve: Motion.drawerCurve }, () => {
      this.drawerOpen = open;
      this.drawerDrag = 0;
    });
  }

  // 0 when closed, 1 when fully open; follows the finger while the drawer is dragged.
  private drawerProgress(): number {
    return this.drawerOpen ? Math.max(0, 1 + this.drawerDrag / this.drawerWidth) : 0;
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
      MenuItemGroup({ header: t("助手") }) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.lightbulb')), content: t("长期记忆") })
          .enabled(!this.app.busy).onClick(() => this.openTools('memory'))
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.doc_plaintext')), content: t("提示词模板") })
          .enabled(!this.app.busy).onClick(() => this.openTools('templates'))
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.connection')), content: t("MCP 服务") })
          .enabled(!this.app.busy).onClick(() => this.openTools('mcp'))
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')), content: t("助手设置与用量") })
          .enabled(!this.app.busy).onClick(() => this.paths.pushPath({ name: 'assistant' }))
      }
    }
  }

  @Builder
  destination(name: string, param: Object) {
    if (name === 'branches') {
      NavDestination() { BranchesPanel({ app: this.app, onSelected: () => this.paths.clear() }) }.title(t("会话分支")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'assistant') {
      NavDestination() { AssistantPanel({ app: this.app }) }.title(t("助手")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'productivity') {
      NavDestination() { ProductivityPanel({ app: this.app, tab: (param as string) || 'memory', onUse: () => { this.paths.clear(); } }) }
        .title(t("记忆与工具")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'files') {
      WorkspacePanel({ app: this.app })
    } else if (name === 'settings') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings,
          onSkills: () => { this.paths.pushPath({ name: 'skills' }); },
          onPrompt: () => { this.paths.pushPath({ name: 'prompt' }); },
          onEditProvider: (id: string, preset: string) => {
            this.app.beginProvider(preset, id);
            this.paths.pushPath({ name: 'provider' });
          } })
      }.title(t("设置")).backgroundColor($r('app.color.page_background'))
    } else if (name === 'prompt') {
      NavDestination() {
        SystemPromptPanel({ app: this.app, settings: this.app.settings, onSaved: () => { this.paths.pop(); } })
      }.title(t("系统提示")).backgroundColor($r('app.color.page_background'))
        .onHidden(() => { this.app.settings.systemPrompt = this.app.config.systemPrompt; })
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
        .opacity(Math.max(0, 1 + this.drawerDrag / this.drawerWidth))
        .transition(TransitionEffect.OPACITY)
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
      .translate({ x: this.drawerDrag })
      .transition(TransitionEffect.translate({ x: -DRAWER_MAX_WIDTH }))
      .onAreaChange((_old: Area, next: Area) => { this.drawerWidth = Math.max(1, next.width as number); })
      .gesture(PanGesture({ direction: PanDirection.Horizontal })
        .onActionUpdate((event: GestureEvent) => { this.drawerDrag = Math.min(0, event.offsetX); })
        .onActionEnd(() => {
          if (this.drawerDrag < -this.drawerWidth / 4) {
            this.setDrawer(false);
          } else {
            this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.drawerCurve }, () => { this.drawerDrag = 0; });
          }
        }))
    }.width('100%').height('100%')
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
        .translate({ x: this.drawerProgress() * 28 })
        if (this.drawerOpen) {
          this.drawer()
        }
      }.width('100%').height('100%')
    }
    .backgroundColor($r('app.color.page_background'))
    .hideTitleBar(true).hideToolBar(true).mode(NavigationMode.Stack)
    .navDestination(this.destination).width('100%').height('100%')
      }, (locale: string) => locale)
    }.width('100%').height('100%')
  }
}
