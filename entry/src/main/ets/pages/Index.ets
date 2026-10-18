import { AppearanceStyle } from '../common/AppearanceStyle';
import { monochromeProviderLogo, providerLogo } from '../common/ProviderBrand';
import { WebUiPreflightHost } from '../views/WebUiPreflightHost';
import { PreviewCaptureHost } from '../views/PreviewCaptureHost';
import { BrowserPanel } from '../views/BrowserPanel';
import { BrowserSession } from '../services/BrowserSession';
import { AnnotationPage, browserAnnotationText } from '../model/BrowserAnnotation';
import { image } from '@kit.ImageKit';
import { Attachments } from '../services/Attachments';
import { t } from '../model/I18n';
import { agentModeName } from '../model/AgentMode';
import { ToolScopePanel } from '../views/ToolScopePanel';
import { ProductivityPanel, ProductivityEditorRoute, productivityEditorTitle } from '../views/ProductivityPanel';
import { ModelSettingsPanel } from '../views/AssistantPanel';
import { BackupPanel } from '../views/BackupPanel';
import { UsagePanel } from '../views/UsagePanel';
import { BranchesPanel } from '../views/BranchesPanel';
import { WorkspacePanel } from '../views/WorkspacePanel';
import { SearchSettingsPanel } from '../views/SearchSettingsPanel';
import { ToolApproval } from '../services/ToolApproval';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { requestAppReview } from '../services/AppInformation';
import { util } from '@kit.ArkTS';
import { KeyboardAvoidMode, SymbolGlyphModifier } from '@kit.ArkUI';
import { Attachment } from '../model/Productivity';
import { writeBytes } from '../services/Attachments';
import { ShareInbox, exportFile, shareFile } from '../services/NativeActions';
import { ChatViewModel, MessageViewModel } from '../viewmodel/ChatViewModel';
import { ChatPanel } from '../views/ChatPanel';
import { SettingsPanel, UserDocumentPanel } from '../views/SettingsPanel';
import { AppearancePanel, appearanceChoiceTitle } from '../views/AppearancePanel';
import { LanguagePanel } from '../views/LanguagePanel';
import { SupportPanel, supportTitle } from '../views/SupportPanel';
import { ThreadList } from '../views/ThreadList';
import { ProviderEditorPanel } from '../views/ProviderEditorPanel';
import { ModelPickerPanel } from '../views/ModelPickerPanel';
import { SkillsPanel } from '../views/SkillsPanel';
import { SkillEditorPanel } from '../views/SkillEditorPanel';
import { SessionService } from '../services/SessionService';
import { createNativeSessionService } from '../services/NativeSessionService';
import { Btn, Motion, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { LaunchActions } from '../services/LaunchActions';
import { OnboardingPanel } from '../views/OnboardingPanel';
import { OnboardingPreferences } from '../services/OnboardingPreferences';

const DRAWER_MAX_WIDTH: number = 340;
const CHAT_HEADER_HEIGHT: number = 56;

@Entry
@Component
struct Index {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @State private app: ChatViewModel = new ChatViewModel();
  @State private drawerOpen: boolean = false;
  @State private drawerContentActive: boolean = false;
  private drawerAnimation: number = 0;
  @State private chatVisible: boolean = true;
  @State private headerProgress: number = 0;
  @State private drawerReveal: number = 0;
  @State private drawerDragging: boolean = false;
  @State private drawerWidth: number = DRAWER_MAX_WIDTH;
  private drawerDragStart: number = 0;
  private paths: NavPathStack = new NavPathStack();
  private session?: SessionService;
  @State private approval: ToolApproval = new ToolApproval();
  @State private browser: BrowserSession = new BrowserSession();
  @State private browserExpanded: boolean = false;
  @State private showToolScope: boolean = false;
  private receiving: boolean = false;
  private ratingOpen: boolean = false;
  private unsubscribeLaunch?: () => void;
  private launching: boolean = false;
  @State private voiceRequest: string = '';
  private onboardingChecked: boolean = false;
  private onboardingDraftThread: string = '';
  private onboardingFinishing: boolean = false;
  @State private onboardingActive: boolean = false;

  onPageShow(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!this.session) {
      this.session = createNativeSessionService(context.filesDir, context.getApplicationContext().filesDir, this.approval, context, this.browser);
      this.session.subscribe((event) => {
        if (event.state.ready && event.state.phase === 'idle' && !event.state.saveError && ShareInbox.peek()) { this.receiveShare(); }
      });
    }
    this.app.initialize(this.session).then(() => {
      ShareInbox.subscribe(() => this.receiveShare());
      if (this.app.ready && !this.unsubscribeLaunch) {
        this.unsubscribeLaunch = LaunchActions.subscribe(() => this.receiveLaunch());
      }
      this.offerOnboarding();
    });
  }

  private onboardingPreferences(): OnboardingPreferences {
    return new OnboardingPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  private offerOnboarding(): void {
    if (!this.app.ready || this.onboardingChecked) { return; }
    this.onboardingChecked = true;
    if (this.receiving || this.launching || ShareInbox.peek() || this.paths.size() > 0) { return; }
    try {
      if (this.onboardingPreferences().shouldShow(this.app.exportSnapshot())) {
        this.onboardingDraftThread = ''; this.onboardingActive = true; this.paths.pushPath({ name: 'onboarding' });
      }
    } catch (error) { this.app.error = t('无法读取首次使用记录：{0}', [(error as Error).message]); }
  }

  private async finishOnboarding(action: string, prompt: string): Promise<void> {
    if (this.onboardingFinishing) { return; }
    this.onboardingFinishing = true;
    try {
      if (action !== 'skip') {
        if (this.app.busy) { throw new Error(t('请先完成当前任务，再开始新的对话。')); }
        await this.app.flushDraft();
        if (this.app.saveError) { throw new Error(this.app.saveError); }
        if (this.onboardingDraftThread !== this.app.active.id) {
          // SessionService owns the full untouched-chat check, including references and queued input.
          if (!await this.app.newThread('')) { throw new Error(this.app.error || this.app.saveError || t('无法创建新对话。')); }
          this.onboardingDraftThread = this.app.active.id;
        }
        this.app.setDraft(prompt); await this.app.flushDraft();
        if (this.app.saveError) { throw new Error(this.app.saveError); }
      }
      this.onboardingPreferences().complete();
      if (action === 'skip') { this.paths.pop(); }
      else { this.paths.clear(); this.setDrawer(false); if (action === 'connect') { this.openSettings(); } }
    } finally { this.onboardingFinishing = false; }
  }

  // Opening a real provider editor must never complete onboarding. The editor's
  // existing onSaved pop returns to the still-mounted model-connection scene.
  private connectOnboardingProvider(preset: string): void {
    if (!this.onboardingActive || this.onboardingFinishing) { return; }
    if (!this.app.beginProvider(preset, '')) { throw new Error(this.app.error || t('请先完成当前任务，再开始新的对话。')); }
    this.onboardingActive = false;
    this.paths.pushPath({ name: 'provider' });
  }

  private async receiveLaunch(): Promise<void> {
    const action = LaunchActions.take();
    if (!action) { return; }
    if (this.launching || this.receiving || this.app.busy || this.app.saveError) {
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('请先完成当前操作或保存，再使用快捷入口。') });
      return;
    }
    this.launching = true;
    try {
      await this.app.flushDraft();
      if (this.app.saveError) { throw new Error(this.app.saveError); }
      if (!LaunchActions.isForeground()) { return; }
      // Desktop shortcuts always create a standalone chat, regardless of the previously selected project.
      if (!await this.app.newThread('')) { throw new Error(this.app.error || this.app.saveError || t('无法创建新对话。')); }
      this.paths.clear(); this.setDrawer(false);
      this.voiceRequest = action === 'voice-input' && LaunchActions.isForeground() ? this.app.active.id : '';
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: (error as Error).message });
    } finally { this.launching = false; }
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
    if (this.browserExpanded) {
      if (this.browser.editingAddress) { this.getUIContext().getFocusController().clearFocus(); return true; }
      if (this.browser.owner === 'user' && this.browser.userBack()) { return true; }
      this.setBrowserExpanded(false); return true;
    }
    if (this.drawerOpen || this.drawerDragging) {
      this.setDrawer(false);
      return true;
    }
    return false;
  }

  private setBrowserExpanded(expanded: boolean): void {
    this.getUIContext().getFocusController().clearFocus();
    this.browserExpanded = expanded;
  }

  private openBrowser(): void {
    if (this.browser.permissionSaving) { return; }
    if (this.browser.policy !== 'enabled') {
      this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('允许启用应用内浏览器？'),
        message: t('启用后，你和 Tinybot 可以使用同一个浏览器。你可以随时接管，也可以在设置中关闭。助手读取的网页内容会发送给当前模型。'),
        primaryButton: { value: t('取消'), action: () => {} },
        secondaryButton: { value: t('允许并启用'), action: () => this.enableAndOpenBrowser() } });
      return;
    }
    try { this.browser.openForUser(); this.setBrowserExpanded(true); }
    catch (error) {
      this.browser.report((error as Error).message);
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: (error as Error).message });
    }
  }

  private async enableAndOpenBrowser(): Promise<void> {
    if (this.browser.permissionSaving) { return; }
    try { await this.browser.setEnabled(true); this.openBrowser(); }
    catch (error) {
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: (error as Error).message });
    }
  }
  private async addBrowserAnnotation(threadId: string, pixel: image.PixelMap, page: AnnotationPage, note: string): Promise<void> {
    if (threadId !== this.app.active.id) { throw new Error(t('对话已切换，请在当前对话重新添加附件。')); }
    if (!this.app.canQueueInput || this.app.active.attachments.length >= 4) { throw new Error(t('当前无法添加附件，请稍后重试。')); }
    const item = await Attachments.saveBrowserAnnotation(pixel);
    await this.app.appendDraftAttachment(threadId, item, browserAnnotationText(page, note));
    this.paths.clear(); this.setDrawer(false); this.setBrowserExpanded(false);
  }

  aboutToDisappear(): void {
    this.unsubscribeLaunch?.(); this.unsubscribeLaunch = undefined;
    this.app.stop();
    this.app.flushDraft();
    this.app.providerEditor.apiKey = '';
  }

  private setDrawer(open: boolean): void {
    this.getUIContext().getFocusController().clearFocus();
    this.drawerDragging = false;
    this.drawerOpen = open;
    if (open) { this.drawerContentActive = true; }
    const animation = ++this.drawerAnimation;
    this.getUIContext().animateTo({ duration: Motion.drawer, curve: Motion.drawerCurve, onFinish: () => {
      if (animation === this.drawerAnimation && !this.drawerOpen && !this.drawerDragging) {
        this.drawerContentActive = false;
      }
    } }, () => {
      this.drawerReveal = open ? 1 : 0;
    });
  }

  private startDrawerDrag(event: GestureEvent, fromChat: boolean = false): void {
    if (!this.app.ready || (fromChat && (this.drawerOpen || event.offsetX <= 0 ||
      event.offsetX <= Math.abs(event.offsetY) * 1.5))) { return; }
    this.getUIContext().getFocusController().clearFocus();
    this.drawerDragStart = this.drawerReveal;
    this.drawerAnimation++;
    this.drawerContentActive = true;
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

  private async openSupport(page: string): Promise<void> {
    if (page === 'guide') {
      this.onboardingDraftThread = ''; this.onboardingActive = true; this.paths.pushPath({ name: 'onboarding' }); return;
    }
    if (page !== 'rating') {
      this.paths.pushPath({ name: 'support', param: page });
      return;
    }
    if (this.ratingOpen) { return; }
    this.ratingOpen = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await requestAppReview(context);
    } catch (error) {
      const failure = error as BusinessError;
      const detail = failure.code ? failure.code + ' · ' + failure.message : failure.message;
      this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('评分和评论'),
        message: t('暂时无法打开评分和评论，请稍后重试。错误：{0}', [detail]),
        confirm: { value: t('关闭'), action: () => {} } });
    } finally { this.ratingOpen = false; }
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
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("已切换到新分支，原对话保留在列表中") });
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
  toolScopeSheet() {
    ToolScopePanel({ app: this.app, thread: this.app.active })
  }

  @Builder
  moreMenu() {
    Menu() {
      MenuItemGroup({ header: t("本对话") }) {
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.wrench_and_screwdriver')),
          content: t('工具范围：{0}', [agentModeName(this.app.active.agentMode)]) }).id('open-tool-scope')
          .enabled(this.app.ready && !this.app.busy && !this.app.active.archived && this.app.saveError.length === 0)
          .onClick(() => { this.showToolScope = true; })
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder')), content: t("工作区文件") })
          .enabled(!this.app.busy).onClick(() => this.openFiles())
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.connection')), content: t('应用内浏览器') })
          .id('open-browser').enabled(this.app.ready && !this.browser.permissionSaving && this.app.saveError.length === 0)
          .onClick(() => this.openBrowser())
        MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.rectangle_stack')), content: t("分支关系") })
          .enabled(!this.app.busy).onClick(() => this.paths.pushPath({ name: 'branches' }))
        MenuItem({ startIcon: $r('app.media.message_branch'), content: t("创建分支") })
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
    if (name === 'onboarding') {
      NavDestination() {
        OnboardingPanel({ active: this.onboardingActive, configured: this.app.configured,
          connectedPreset: this.currentProviderPreset(), busy: this.app.busy,
          onFinish: (action: string, prompt: string) => this.finishOnboarding(action, prompt),
          onConnect: (preset: string) => this.connectOnboardingProvider(preset) })
      }.hideTitleBar(true).backgroundColor($r('app.color.page_background'))
        .onBackPressed(() => {
          this.finishOnboarding('skip', '').catch((error: Error) => {
            this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: error.message });
          });
          return true;
        })
        .onShown(() => { this.onboardingActive = true; })
        .onHidden(() => { this.onboardingActive = false; })
    } else if (name === 'branches') {
      NavDestination() { BranchesPanel({ app: this.app, onSelected: () => this.paths.clear() }) }.title(t("会话分支"), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'appearance') {
      NavDestination() { AppearancePanel({ onChoice: (choice: string) => { this.paths.pushPath({ name: 'appearance-choice', param: choice }); } }) }
        .title(t('界面与外观'), { systemMaterial: this.appearance.control })
        .backgroundColor($r('app.color.page_background'))
    } else if (name === 'appearance-choice') {
      NavDestination() { AppearancePanel({ choice: param as string, onDone: () => { this.paths.pop(); } }) }
        .title(appearanceChoiceTitle(param as string), { systemMaterial: this.appearance.control })
        .backgroundColor($r('app.color.page_background'))
    } else if (name === 'language') {
      NavDestination() { LanguagePanel({ app: this.app }) }.title(t('语言'), { systemMaterial: this.appearance.control })
        .backgroundColor($r('app.color.page_background'))
    } else if (name === 'model-settings') {
      NavDestination() { ModelSettingsPanel({ app: this.app }) }.title(t('模型分工与能力'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'backup') {
      NavDestination() { BackupPanel({ app: this.app }) }.title(t('备份与恢复'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'usage') {
      NavDestination() { UsagePanel({ app: this.app }) }.title(t('Token 用量'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'productivity') {
      NavDestination() { ProductivityPanel({ app: this.app, tab: (param as string) || 'memory', onUse: () => { this.paths.clear(); },
        onEdit: (tab: string, id: string, onReturn: (warning: string) => void) => {
          const request: ProductivityEditorRoute = { tab: tab, id: id };
          this.paths.pushPath({ name: 'productivity-editor', param: request,
            onPop: (info: PopInfo) => { onReturn(typeof info.result === 'string' ? info.result : ''); } });
        } }) }
        .title(t("记忆与工具"), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'productivity-editor') {
      NavDestination() {
        ProductivityPanel({ app: this.app, tab: (param as ProductivityEditorRoute).tab, entryId: (param as ProductivityEditorRoute).id,
          editorOnly: true, onClose: (warning: string) => { this.paths.pop(warning); } })
      }.title(productivityEditorTitle((param as ProductivityEditorRoute).tab, (param as ProductivityEditorRoute).id), { systemMaterial: this.appearance.control })
        .backgroundColor($r('app.color.page_background')).onBackPressed(() => this.app.busy)
    } else if (name === 'search-settings') {
      NavDestination() { SearchSettingsPanel({ app: this.app }) }.title(t('搜索服务'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'files') {
      WorkspacePanel({ app: this.app, initialPath: (param as string) || '' })
    } else if (name === 'settings') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings,
          browser: this.browser,
          onAddProvider: () => { this.paths.pushPath({ name: 'provider-presets' }); },
          onUsage: () => { this.paths.pushPath({ name: 'usage' }); },
          onModels: () => { this.paths.pushPath({ name: 'model-settings' }); },
          onSearch: () => { this.paths.pushPath({ name: 'search-settings' }); },
          onAppearance: () => { this.paths.pushPath({ name: 'appearance' }); },
          onLanguage: () => { this.paths.pushPath({ name: 'language' }); },
          onBackup: () => { this.paths.pushPath({ name: 'backup' }); },
          onSupport: (page: string) => this.openSupport(page),
          onTools: (tab: string) => this.openTools(tab),
          onSkills: () => { this.paths.pushPath({ name: 'skills' }); },
          onUserDocument: () => { this.paths.pushPath({ name: 'user-document' }); },
          onEditProvider: (id: string, preset: string) => {
            if (this.app.beginProvider(preset, id)) { this.paths.pushPath({ name: 'provider' }); }
          } })
      }.title(t("设置"), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'provider-presets') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings, browser: this.browser, presetsOnly: true,
          onEditProvider: (_id: string, preset: string) => {
            if (this.app.beginProvider(preset, '')) { this.paths.replacePath({ name: 'provider' }); }
          } })
      }.title(t('添加模型服务'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'support') {
      NavDestination() {
        SupportPanel({ page: param as string,
          onOpen: (page: string) => this.openSupport(page) })
      }.title(supportTitle(param as string), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'user-document') {
      NavDestination() {
        UserDocumentPanel({ app: this.app, settings: this.app.settings, onSaved: () => { this.paths.pop(); } })
      }.title(t('称呼与回答偏好'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
        .onHidden(() => { this.app.settings.userDocument = this.app.config.userDocument || ''; })
    } else if (name === 'skills') {
      NavDestination() {
        SkillsPanel({ app: this.app, onEdit: (skill: string) => {
          this.app.beginSkill(skill);
          this.paths.pushPath({ name: 'skill-editor' });
        }, onUse: () => { this.paths.clear(); } })
      }.title('Skills', { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'skill-editor') {
      NavDestination() {
        SkillEditorPanel({ app: this.app, editor: this.app.skillEditor, onSaved: () => { this.paths.pop(); } })
      }.title(this.app.skillEditor.originalName.length > 0 ? t("编辑 Skill") : t("添加 Skill"), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'provider') {
      NavDestination() {
        ProviderEditorPanel({ app: this.app, editor: this.app.providerEditor, onSaved: () => { this.paths.pop(); },
          onModels: (error: string) => { this.paths.pushPath({ name: 'provider-models', param: error }); },
          onDiscovered: (models: string[]) => { this.paths.pushPath({ name: 'provider-discovery', param: models }); } })
      }.title(this.app.providerEditor.id.length > 0 ? t("编辑服务") : t("添加服务"), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
        .onBackPressed(() => {
          if (this.app.busy) { return true; }
          if (!this.app.providerEditor.hasChanges) { return false; }
          this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('放弃未保存的修改？'), message: t('离开后，本次对服务配置的修改不会保存。'),
            primaryButton: { value: t('继续编辑'), action: () => {} },
            secondaryButton: { value: t('放弃修改'), fontColor: $r('app.color.danger'), action: () => { this.paths.pop(); } } });
          return true;
        })
    } else if (name === 'provider-models') {
      NavDestination() {
        ProviderEditorPanel({ app: this.app, editor: this.app.providerEditor, page: 'models', initialModelError: (param as string) || '',
          onSaved: () => { this.paths.pop(); } })
      }.title(t('管理模型'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'provider-discovery') {
      NavDestination() {
        ProviderEditorPanel({ app: this.app, editor: this.app.providerEditor, page: 'discovery', foundModels: param as string[],
          onSaved: () => { this.paths.pop(); } })
      }.title(t('选择要添加的模型'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'models') {
      NavDestination() {
        ModelPickerPanel({ app: this.app, onSelected: () => { this.paths.pop(); }, onSettings: () => this.openSettings() })
      }.title(t("选择模型"), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    }
  }

  private currentProviderPreset(): string {
    return this.app.providerProfiles.find((profile) => profile.id === this.app.active.modelRef?.providerId)?.presetId || '';
  }

  private modelSubtitle(): string {
    if (!this.app.ready) { return t('你的随身 AI 助手'); }
    const reference = this.app.active.modelRef;
    return reference ? reference.modelId + (this.app.configured ? '' : t(' · 不可用')) : t('选择模型');
  }

  @Builder
  header() {
    Stack() {
      Column().id('chat-header-backdrop').width('100%').height(CHAT_HEADER_HEIGHT)
        .backgroundEffect({ radius: 12, color: $r('app.color.chat_header_background') })
        .translate({ y: -CHAT_HEADER_HEIGHT * this.headerProgress }).opacity(1 - this.headerProgress)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    Row({ space: 4 }) {
      IconButton({ icon: $r('sys.symbol.line_3_horizontal'), label: t("对话列表"), compId: 'open-history',
        material: this.appearance.control, tint: $r('sys.color.font_primary'),
        disabled: !this.app.ready, onTap: () => this.setDrawer(true) })
      Column({ space: 1 }) {
        Text(this.app.ready ? (this.app.activeProject ? this.app.activeProject.name + ' · ' : '') + this.app.active.displayTitle : 'Tinybot').fontSize(16).fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Row({ space: 4 }) {
          if (this.app.ready && this.app.active.teamEnabled) {
            SymbolGlyph($r('sys.symbol.person_2')).fontSize(12).fontColor([this.appearance.accent]).margin({ right: 2 })
              .accessibilityText(t("团队模式已开启"))
          }
          if (this.app.ready && this.app.active.modelRef) {
            if (providerLogo(this.currentProviderPreset())) {
              if (monochromeProviderLogo(this.currentProviderPreset())) {
                Image(providerLogo(this.currentProviderPreset())).width(14).height(14).objectFit(ImageFit.Contain)
                  .fillColor($r('app.color.text_secondary')).flexShrink(0).accessibilityLevel('no')
              } else {
                Image(providerLogo(this.currentProviderPreset())).width(14).height(14).objectFit(ImageFit.Contain)
                  .flexShrink(0).accessibilityLevel('no')
              }
            } else {
              SymbolGlyph($r('sys.symbol.cloud')).fontSize(14).fontColor([$r('app.color.text_secondary')])
                .flexShrink(0).accessibilityLevel('no')
            }
            Text('·').fontSize(12).fontColor($r('app.color.text_secondary')).flexShrink(0).accessibilityLevel('no')
          }
          Text(this.modelSubtitle()).fontSize(12).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
            .fontColor(this.app.ready && !this.app.configured ? $r('app.color.danger') : $r('app.color.text_secondary'))
          if (this.app.ready) {
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.text_secondary')])
          }
        }.justifyContent(FlexAlign.Center).constraintSize({ maxWidth: '100%' })
      }
      .id('open-model-picker').layoutWeight(1).padding({ top: 4, bottom: 4 }).borderRadius(12)
      .translate({ y: -CHAT_HEADER_HEIGHT * this.headerProgress }).opacity(1 - this.headerProgress)
      .hitTestBehavior(this.headerProgress < 1 ? HitTestMode.Default : HitTestMode.None)
      .accessibilityLevel(this.headerProgress < 1 ? 'auto' : 'no-hide-descendants')
      .accessibilityText(t("切换模型：") + this.app.currentModelLabel)
      .enabled(this.app.ready && !this.app.busy && !this.app.active.archived)
      .onClick(() => { this.paths.pushPath({ name: 'models' }); })
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(20).fontColor([$r('sys.color.font_primary')])
      }.id('chat-more').width(44).height(44).borderRadius(22).backgroundColor(Color.Transparent)
      .systemMaterial(this.appearance.control).accessibilityText(t("更多操作"))
      .enabled(this.app.ready).bindMenu(this.moreMenu, {
        systemMaterial: this.appearance.surface, mask: false })
      IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t("新建对话"), compId: 'new-chat',
        material: this.appearance.control, tint: $r('sys.color.font_primary'),
        disabled: !this.app.ready || this.app.busy || this.app.saveError.length > 0,
        onTap: () => { this.app.newThread(); } })
    }.width('100%').height(CHAT_HEADER_HEIGHT).padding({ left: 6, right: 6 })
      .hitTestBehavior(HitTestMode.Transparent)
    }.width('100%').height(CHAT_HEADER_HEIGHT).clip(true).hitTestBehavior(HitTestMode.Transparent)
    .translate({ x: this.drawerReveal * 28 })
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
        ThreadList({ app: this.app, active: this.drawerContentActive, onSelected: () => this.setDrawer(false), onFiles: () => { this.setDrawer(false); this.openFiles(); }, onSettings: () => {
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
    Stack() {
      ForEach([this.locale], (_locale: string) => {
    Stack() {
    Navigation(this.paths) {
      Stack() {
        // Render the capture card at chat width behind the opaque page.
        PreviewCaptureHost()
        Column().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        Column() {
          if (this.app.ready) {
            ChatPanel({ app: this.app, thread: this.app.active, approval: this.approval, browser: this.browser,
                onBrowser: () => this.setBrowserExpanded(true), onSettings: () => this.openSettings(),
                topInset: CHAT_HEADER_HEIGHT,
                onHeaderProgress: (progress: number): void => { this.headerProgress = progress; },
                voiceRequest: this.voiceRequest, onVoiceShortcutConsumed: () => { this.voiceRequest = ''; },
                activeThreadId: this.app.active.id, speechEnabled: this.chatVisible && !this.drawerOpen && !this.drawerDragging && !this.browserExpanded,
                onHistoryDragStart: (event: GestureEvent) => this.startDrawerDrag(event, true),
                onHistoryDragUpdate: (event: GestureEvent) => this.updateDrawerDrag(event),
                onHistoryDragEnd: (event: GestureEvent) => this.endDrawerDrag(event),
                onHistoryDragCancel: () => this.cancelDrawerDrag(),
                onFiles: () => this.openFiles(), onOpenFile: (path: string) => this.paths.pushPath({ name: 'files', param: path }),
                onTools: (tab: string) => this.openTools(tab) })
              .layoutWeight(1)
          } else {
            Column({ space: Space.lg }) {
              if (this.app.loading) {
                LoadingProgress().width(32).height(32).color(this.appearance.accent)
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
        WebUiPreflightHost()
      }.width('100%').height('100%')
    }
    .backgroundColor($r('app.color.page_background'))
    // Native button materials only work inside the actual navigation title bar.
    .title({ builder: this.header, height: CHAT_HEADER_HEIGHT }, {
      barStyle: BarStyle.STACK, backgroundColor: Color.Transparent,
      backgroundEffect: { radius: 0, color: Color.Transparent }
    })
    .hideBackButton(true).titleMode(NavigationTitleMode.Mini).hideToolBar(true).mode(NavigationMode.Stack)
    .onNavBarStateChange((visible: boolean) => { this.chatVisible = visible; })
    .navDestination(this.destination).width('100%').height('100%')
    // Cover both the navigation title bar and content, keeping the measured drawer mounted.
    if (this.app.ready) {
      this.drawer()
    }
    }.width('100%').height('100%')
      }, (locale: string) => locale)
      BrowserPanel({ browser: this.browser, expanded: this.browserExpanded,
        threadId: this.app.active.id, canAnnotate: this.app.canQueueInput && this.app.active.attachments.length < 4,
        onAnnotation: (threadId: string, pixel: image.PixelMap, page: AnnotationPage, note: string) => this.addBrowserAnnotation(threadId, pixel, page, note),
        onSettings: () => { this.setBrowserExpanded(false); this.openSettings(); },
        onDismiss: () => this.setBrowserExpanded(false) })
    }.width('100%').height('100%')
    .bindSheet($$this.showToolScope, this.toolScopeSheet(), { title: { title: t('工具范围') },
      height: this.app.active.agentMode === 'custom' ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
      dragBar: true, backgroundColor: $r('app.color.page_background'), systemMaterial: this.appearance.readingSurface })
  }
}
