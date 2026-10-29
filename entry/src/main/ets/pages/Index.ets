import { ConversationShareData, sharingMessages } from '../model/ConversationShare';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { ConversationSharePanel } from '../views/ConversationSharePanel';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { systemMaterialAttribute } from '../common/MaterialAttributes';
import { monochromeProviderLogo, providerLogo } from '../common/ProviderBrand';
import { WebUiPreflightHost } from '../views/WebUiPreflightHost';
import { PreviewCaptureHost } from '../views/PreviewCaptureHost';
import { BrowserPanel } from '../views/BrowserPanel';
import { BrowserSession } from '../services/BrowserSession';
import { AnnotationPage, browserAnnotationText } from '../model/BrowserAnnotation';
import { image } from '@kit.ImageKit';
import { Attachments } from '../services/Attachments';
import { MAX_MESSAGE_ATTACHMENTS } from '../model/Productivity';
import { getLocale, t } from '../model/I18n';
import { agentModeName } from '../model/AgentMode';
import { ToolScopePanel } from '../views/ToolScopePanel';
import { ProductivityPanel, ProductivityEditorRoute, productivityEditorTitle } from '../views/ProductivityPanel';
import { ModelSettingsPanel } from '../views/AssistantPanel';
import { BackupPanel } from '../views/BackupPanel';
import { UsagePanel } from '../views/UsagePanel';
import { StorageCategoryPanel, StoragePanel } from '../views/StoragePanel';
import { storageCategoryKey } from '../model/StoragePlan';
import { BranchesPanel } from '../views/BranchesPanel';
import { WorkspacePanel } from '../views/WorkspacePanel';
import { MiniAppsPanel } from '../views/MiniAppsPanel';
import { SearchSettingsPanel } from '../views/SearchSettingsPanel';
import { SearchProviderPanel } from '../views/SearchProviderPanel';
import { SearchEditorDraft, SearchProviderRoute, searchProviderName } from '../model/SearchEditor';
import { ToolApproval } from '../services/ToolApproval';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { requestAppReview } from '../services/AppInformation';
import { ReviewPreferences } from '../services/ReviewPreferences';
import { ReviewChoice, ReviewInvitationDialog } from '../views/ReviewInvitationDialog';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { materialMenuContent, materialMenuHeader } from '../common/MaterialMenu';
import { ShareInbox } from '../services/NativeActions';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
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
import { Btn, Motion, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { LaunchActions } from '../services/LaunchActions';
import { OnboardingPanel } from '../views/OnboardingPanel';
import { OnboardingPreferences } from '../services/OnboardingPreferences';
import { StartupBackup } from '../services/StartupBackup';
import { CloudBackup, CloudBackupItem, cloudBackupError } from '../services/CloudBackup';
import { StartupBackupDialog } from '../views/StartupBackupDialog';
import { HuaweiAccount, huaweiAccount } from '../services/HuaweiAccount';
import { HuaweiAccountPanel } from '../views/HuaweiAccountPanel';
import { HostedPrivacy, hostedPrivacy } from '../services/HostedPrivacy';
import { announcements } from '../services/Announcements';
import { AnnouncementDialog } from '../views/AnnouncementDialog';
import { Diagnostics } from '../model/Diagnostics';
import { WorkbenchLayout } from '../model/WorkbenchLayout';
import { PreviewPanel } from '../views/PreviewPanel';
import { AnimatedPage } from '../common/AnimatedPage';
import { HistoryRail } from '../views/HistoryRail';
import { PaneDivider } from '../common/PaneDivider';
import { DetailLauncher } from '../views/DetailLauncher';
import { DetailTabItem, DetailTabs } from '../views/DetailTabs';

const DRAWER_MAX_WIDTH: number = 340;
const CHAT_HEADER_HEIGHT: number = 56;

@Entry
@Component
struct Index {
  @State private privacy: HostedPrivacy = hostedPrivacy;
  @StorageProp('tinybot.privacy.allowed') @Watch('privacyChanged') private privacyAllowed: boolean = false;
  @StorageProp('tinybot.foreground') @Watch('foregroundChanged') private foreground: boolean = false;
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @State private app: ChatViewModel = new ChatViewModel();
  @State private account: HuaweiAccount = huaweiAccount;
  @State private windowWidth: number = 0;
  @State private workspaceOpen: boolean = false;
  @State private workspacePresent: boolean = false;
  @State private previewPresent: boolean = false;
  @State private browserPresent: boolean = false;
  @State private previewVisible: boolean = false;
  private browserClosing: boolean = false;
  @State private workspacePath: string = '';
  @State private workspaceRequest: number = 0;
  @State private workspaceCloseRequest: number = 0;
  @State private workspaceTabCloseRequest: number = 0;
  // Docked detail panes are tabs. Presence flags above stay the source of truth
  // for each panel; these track order, focus and whether the column is shown.
  @State private detailPaneOpen: boolean = false;
  // 0 = the column is fully off-screen, 1 = fully docked. The chat width and
  // the column geometry both read this value so they move as one animation.
  @State private detailReveal: number = 0;
  // Kept true until the close animation completes: the reveal state already
  // holds its 0 target, so it cannot by itself keep the host visible.
  @State private detailClosing: boolean = false;
  @State private detailClosingLauncher: boolean = false;
  private detailAnim: number = 0;
  @State private detailTabs: string[] = [];
  @State private activeDetailTab: string = '';
  @State private previewId: string = '';
  @State private previewMessageId: string = '';
  @State private previewThreadId: string = '';
  @State private drawerOpen: boolean = false;
  @State private drawerContentActive: boolean = false;
  private drawerAnimation: number = 0;
  // History column preference: collapsed shows the rail, the width only changes on drag.
  @State private historyCollapsed: boolean = false;
  @State private historyPreferredWidth: number = 0;
  @State private detailPreferredWidth: number = 0;
  @State private historySearchRequest: number = 0;
  @State private miniAppAddAvailable: boolean = false;
  @State private miniAppAddRequest: number = 0;
  private resizeBase: number = 0;
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
  @State @Watch('offerAnnouncement') private browserExpanded: boolean = false;
  @State @Watch('offerAnnouncement') private showToolScope: boolean = false;
  private announcementDialog?: CustomDialogController;
  private receiving: boolean = false;
  private ratingOpen: boolean = false;
  private reviewDialog?: CustomDialogController;
  private reviewTimer: number = -1;
  private reviewAfterDismiss: boolean = false;
  private reviewDisposed: boolean = false;
  private unsubscribeLaunch?: () => void;
  private launching: boolean = false;
  @State private voiceRequest: string = '';
  private startupBackup?: StartupBackup;
  private startupBackupChecking: boolean = false;
  private startupBackupRestoring: boolean = false;
  private startupBackupDialog?: CustomDialogController;
  private onboardingChecked: boolean = false;
  private onboardingDraftThread: string = '';
  private onboardingFinishing: boolean = false;
  @State private onboardingActive: boolean = false;
  @State private providerEditorActive: boolean = false;

  onPageShow(): void {
    this.reviewDisposed = false;
    this.paths.disableAnimation(false);
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    if (!this.privacy.allowed) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    announcements.checkOnStartup(context).then(() => this.offerAnnouncement());
    this.account.initialize(context).then(() => this.account.refresh());
    if (!this.session) {
      try { this.startupBackup = new StartupBackup(context); }
      catch (error) { Diagnostics.log('warn', 'backup', 'startup_capture_failed', undefined, error as Error); }
      this.session = createNativeSessionService(context.filesDir, context.getApplicationContext().filesDir, this.approval, context, this.browser);
      this.session.subscribe((event) => {
        if (event.state.canNavigate && ShareInbox.peek()) { this.receiveShare(); }
        if (event.kind === 'task-complete' && event.threadId) { this.taskCompleted(event.threadId); }
      });
    }
    this.app.initialize(this.session).then(() => {
      if (!this.privacy.allowed) { return; }
      ShareInbox.subscribe(() => this.receiveShare());
      if (this.app.ready && !this.unsubscribeLaunch) {
        this.unsubscribeLaunch = LaunchActions.subscribe(() => this.receiveLaunch());
      }
      this.offerOnboarding();
      this.offerStartupBackup();
      this.offerAnnouncement();
    });
  }

  private offerAnnouncement(): void {
    if (!this.privacy.allowed || !this.foreground || !this.app.ready || !this.onboardingChecked || this.startupBackupChecking || this.startupBackupDialog ||
      this.paths.size() > 0 || this.browserExpanded || this.showToolScope || this.ratingOpen || this.reviewDialog || this.announcementDialog) { return; }
    const item = announcements.pending();
    if (!item) { return; }
    // Tablets and wide windows follow the window width; 0 keeps the platform default.
    const width = WorkbenchLayout.dialogWidth(this.windowWidth);
    try {
      this.announcementDialog = new CustomDialogController({
        builder: AnnouncementDialog({ announcement: item, onConfirm: () => {
          announcements.acknowledge(item.id);
          this.closeAnnouncement();
        } }),
        // A dense frosted backing keeps long announcements readable over arbitrary chat content.
        systemMaterial: this.appearance.noMaterial,
        backgroundBlurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
        backgroundBlurStyleOptions: {
          colorMode: AppStorage.get<boolean>('tinybot.appearance.dark') === true ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
        },
        autoCancel: false, alignment: DialogAlignment.Center,
        width: width > 0 ? width : undefined,
        onDidAppear: () => {
          if (!this.privacy.allowed) { this.closeAnnouncement(); return; }
          announcements.didOffer();
        },
        onDidDisappear: () => { this.announcementDialog = undefined; }
      });
      this.announcementDialog.open();
    } catch (error) {
      this.announcementDialog = undefined;
      Diagnostics.log('error', 'announcements', 'present_failed', undefined, error as Error);
    }
  }

  private closeAnnouncement(): void {
    this.announcementDialog?.close();
  }

  private reviewPreferences(): ReviewPreferences {
    return new ReviewPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  private reviewSaveFailed(error: Error): void {
    Diagnostics.log('error', 'review', 'save_failed', undefined, error);
    this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface,
      message: t('无法保存评分邀请记录：{0}', [error.message]) });
  }

  private taskCompleted(threadId: string): void {
    if (!this.privacy.allowed || this.reviewDisposed) { return; }
    try {
      const history = this.reviewPreferences(); history.recordTask();
      Diagnostics.log('info', 'review', 'task_completed');
      if (!this.foreground || !history.shouldAsk(Date.now())) { return; }
    } catch (error) { this.reviewSaveFailed(error as Error); return; }
    clearTimeout(this.reviewTimer);
    // Let the final answer settle and queued work finish. A blocked opportunity is discarded,
    // never replayed on startup, foreground entry or return from a settings page.
    this.reviewTimer = setTimeout(() => { this.reviewTimer = -1; this.offerReviewInvitation(threadId); }, 1500);
  }

  private canOfferReview(threadId: string): boolean {
    return !this.reviewDisposed && this.privacy.allowed && this.foreground && this.app.ready && !this.app.busy &&
      !this.app.error && !this.app.saveError && this.app.active.id === threadId && !this.app.draft.trim() &&
      this.app.active.attachments.length === 0 && this.app.active.references.length === 0 &&
      this.app.active.pendingInputs.length === 0 && this.paths.size() === 0 && this.chatVisible &&
      !this.onboardingActive && !this.startupBackupDialog && !this.startupBackupRestoring && !this.receiving && !this.launching && !ShareInbox.peek() &&
      !this.drawerOpen && !this.drawerDragging && !this.detailPaneOpen && !this.browserExpanded && !this.showToolScope &&
      !this.voiceRequest && !this.approval.title && !this.approval.form && !this.ratingOpen &&
      !this.announcementDialog && !announcements.loading && !announcements.pending();
  }

  private offerReviewInvitation(threadId: string): void {
    if (this.reviewDialog || !this.canOfferReview(threadId)) { return; }
    try {
      if (!this.reviewPreferences().shouldAsk(Date.now())) { return; }
      const width = WorkbenchLayout.dialogWidth(this.windowWidth);
      this.reviewDialog = new CustomDialogController({
        builder: ReviewInvitationDialog({ onChoose: (choice: ReviewChoice) => this.chooseReviewInvitation(choice) }),
        systemMaterial: this.appearance.surface, autoCancel: true, alignment: DialogAlignment.Center,
        width: width > 0 ? width : undefined,
        onDidAppear: () => {
          if (!this.canOfferReview(threadId)) { this.closeReviewInvitation(); return; }
          try { this.reviewPreferences().didAsk(Date.now()); Diagnostics.log('info', 'review', 'presented'); }
          catch (error) { this.closeReviewInvitation(); this.reviewSaveFailed(error as Error); }
        },
        onDidDisappear: () => {
          const open = this.reviewAfterDismiss; this.reviewAfterDismiss = false; this.reviewDialog = undefined;
          if (open && !this.reviewDisposed && this.privacy.allowed && this.foreground) { this.openSupport('rating'); }
        }
      });
      this.reviewDialog.open();
    } catch (error) {
      this.reviewDialog = undefined;
      Diagnostics.log('error', 'review', 'present_failed', undefined, error as Error);
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface,
        message: t('无法显示评分邀请：{0}', [(error as Error).message]) });
    }
  }

  private chooseReviewInvitation(choice: ReviewChoice): void {
    if (choice === 'never') {
      try { this.reviewPreferences().stopInvitations(); }
      catch (error) { Diagnostics.log('error', 'review', 'save_failed', undefined, error as Error); throw error as Error; }
    }
    Diagnostics.log('info', 'review', choice === 'review' ? 'accepted' : choice === 'never' ? 'disabled' : 'deferred');
    this.reviewAfterDismiss = choice === 'review'; this.reviewDialog?.close();
  }

  private closeReviewInvitation(): void {
    this.cancelReviewOffer(); this.reviewAfterDismiss = false;
    this.reviewDialog?.close();
  }

  private cancelReviewOffer(): void {
    clearTimeout(this.reviewTimer); this.reviewTimer = -1;
  }

  private foregroundChanged(): void {
    if (!this.foreground) { this.closeReviewInvitation(); this.startupBackupDialog?.close(); }
    if (this.foreground) { this.offerStartupBackup(); }
    this.offerAnnouncement();
  }

  private onboardingPreferences(): OnboardingPreferences {
    return new OnboardingPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  private privacyChanged(): void {
    if (this.privacyAllowed) { this.onPageShow(); }
    else {
      this.closeAnnouncement();
      this.closeReviewInvitation(); this.startupBackupDialog?.close();
      this.app.stop(); this.browser.close(); this.browserExpanded = false; this.showToolScope = false;
      this.voiceRequest = ''; this.paths.clear(); this.setDrawer(false);
      this.workspaceOpen = false; this.previewVisible = false; this.previewId = '';
      this.detailAnim++; this.detailPaneOpen = false; this.detailReveal = 0; this.detailClosing = false;
      this.detailClosingLauncher = false; this.detailTabs = []; this.activeDetailTab = '';
      this.workspacePresent = false; this.previewPresent = false; this.browserPresent = false; this.browserClosing = false;
    }
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

  private canOfferStartupBackup(): boolean {
    return !this.reviewDisposed && this.privacy.allowed && this.foreground && this.app.ready && this.app.canNavigate &&
      !this.app.busy && !this.receiving && !this.launching && !ShareInbox.peek() && !this.providerEditorActive &&
      !this.announcementDialog && !this.reviewDialog && (this.paths.size() === 0 || this.onboardingActive) &&
      this.startupBackup !== undefined && this.startupBackup.untouched(this.app.exportSnapshot());
  }

  private async offerStartupBackup(): Promise<void> {
    if (!this.startupBackup || this.startupBackupChecking || this.startupBackupDialog || !this.canOfferStartupBackup()) { return; }
    this.startupBackupChecking = true;
    try {
      const item = await this.startupBackup.find(this.app.exportSnapshot());
      if (!item || !this.canOfferStartupBackup()) { return; }
      const width = WorkbenchLayout.dialogWidth(this.windowWidth);
      this.startupBackupDialog = new CustomDialogController({
        builder: StartupBackupDialog({ date: new Date(item.createdAt).toLocaleString(getLocale()),
          onRestore: () => this.restoreStartupBackup(item) }),
        systemMaterial: this.appearance.surface, autoCancel: false, alignment: DialogAlignment.Center,
        width: width > 0 ? width : undefined,
        onDidAppear: () => {
          if (!this.canOfferStartupBackup()) { this.startupBackupDialog?.close(); return; }
          try { this.startupBackup?.finish(); }
          catch (error) {
            this.startupBackupDialog?.close();
            this.app.error = (error as Error).message;
            Diagnostics.log('error', 'backup', 'startup_marker_failed', undefined, error as Error);
          }
        },
        onDidDisappear: () => {
          this.startupBackupDialog = undefined;
          if (!this.reviewDisposed && this.privacy.allowed && this.foreground) {
            this.receiveShare(); this.receiveLaunch(); this.offerAnnouncement();
          }
        }
      });
      this.startupBackupDialog.open();
    } catch (error) {
      this.startupBackupDialog = undefined;
      Diagnostics.log('warn', 'backup', 'startup_lookup_failed', undefined, error as Error);
    } finally { this.startupBackupChecking = false; this.offerAnnouncement(); }
  }

  private async restoreStartupBackup(item: CloudBackupItem): Promise<void> {
    if (this.startupBackupRestoring || !this.canOfferStartupBackup()) { throw new Error(t('当前已开始配置，请到设置中手动恢复备份。')); }
    this.startupBackupRestoring = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const restored = await CloudBackup.restore(context, item.name, this.app.exportSnapshot());
      if (!this.canOfferStartupBackup()) { throw new Error(t('当前已开始配置，请到设置中手动恢复备份。')); }
      if (!await this.app.importSnapshot(restored)) { throw new Error(this.app.error || this.app.saveError); }
      this.onboardingPreferences().complete();
      this.paths.clear(); this.onboardingActive = false;
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('备份已恢复，已跳过已有内容') });
    } catch (error) { throw new Error(cloudBackupError(error as Error)); }
    finally { this.startupBackupRestoring = false; }
  }

  private async finishOnboarding(action: string, prompt: string): Promise<void> {
    if (this.onboardingFinishing) { return; }
    this.onboardingFinishing = true;
    try {
      if (action !== 'skip') {
        if (!this.app.canNavigate) { throw new Error(t('无法创建新对话。')); }
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

  private async createChat(): Promise<void> {
    if (!this.app.canNavigate) { return; }
    const previousId = this.app.active.id;
    // SessionService decides whether the current chat is untouched and reusable.
    if (!await this.app.newThread()) { return; }
    this.revealChat();
    if (this.app.active.id === previousId) {
      this.getUIContext().getPromptAction().showToast({
        systemMaterial: this.appearance.surface, message: t('已在新对话中'), duration: 1600
      });
    }
  }

  private async receiveLaunch(): Promise<void> {
    if (!this.privacy.allowed || this.startupBackupDialog || this.startupBackupRestoring) { return; }
    const action = LaunchActions.take();
    if (!action) { return; }
    // The session restores the last active chat on cold start. Returning to it must
    // not create a chat, flush/replace a draft, or interrupt a running answer.
    if (action === 'continue-chat') {
      const threadId = LaunchActions.takeThreadId();
      if (this.launching || this.receiving || this.onboardingActive) { return; }
      if (threadId && threadId !== this.app.active.id) {
        this.launching = true;
        try {
          await this.app.flushDraft();
          if (this.app.saveError) { throw new Error(this.app.saveError); }
          if (!LaunchActions.isForeground()) { return; }
          if (!await this.app.selectThread(threadId)) {
            throw new Error(this.app.error || this.app.saveError || t('无法打开通知对应的对话。'));
          }
        } catch (error) {
          this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: (error as Error).message });
          return;
        } finally { this.launching = false; }
      }
      this.voiceRequest = '';
      this.revealChat();
      return;
    }
    if (this.launching || this.receiving || !this.app.canNavigate) {
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
      this.revealChat();
      this.voiceRequest = action === 'voice-input' && LaunchActions.isForeground() ? this.app.active.id : '';
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: (error as Error).message });
    } finally { this.launching = false; }
  }

  private async receiveShare(): Promise<void> {
    if (!this.privacy.allowed) { return; }
    if (this.receiving || this.startupBackupDialog || this.startupBackupRestoring || !this.session || !this.app.ready) { return; }
    this.receiving = true;
    try {
      if (!this.session.canNavigate) { return; }
      let input = ShareInbox.peek();
      while (input) {
        if (input.error) { this.app.error = input.error; }
        else if (await this.app.newThread()) {
          this.app.setDraft(input.text);
          if (!await this.app.setAttachments(input.attachments)) { return; }
          await this.app.flushDraft(); this.revealChat();
          if (this.app.saveError) { return; }
        } else { return; }
        ShareInbox.take(); input = ShareInbox.peek();
      }
    } finally { this.receiving = false; }
  }

  private revealChat(): void {
    this.paths.clear(); this.setDrawer(false);
    // Collapse the phone overlay without disposing retained editors or their drafts.
    if (!this.workbench().docked) { this.setDetailPane(false); }
  }

  private hasPreview(): boolean { return this.previewId.length > 0 && this.previewThreadId === this.app.active.id; }
  // The pane stays laid out through its exit animations: the reveal keeps an
  // empty launcher visible while it slides away, and the presence flags are
  // raised until AnimatedPage reports that an outgoing body is gone.
  private detailOpen(): boolean {
    return !!(this.detailPaneOpen || this.detailClosing || this.workspacePresent ||
      this.previewPresent || this.browserPresent);
  }

  // Geometry for the open column, independent of the exit-presence flags. The
  // reveal scales this width so the chat gains exactly what the column loses.
  private detailGeometry(): WorkbenchLayout {
    return new WorkbenchLayout(this.windowWidth, true, !this.historyCollapsed,
      this.historyPreferredWidth, this.detailPreferredWidth);
  }

  private setDetailPane(open: boolean, fromLauncher: boolean = false): void {
    const token = ++this.detailAnim;
    this.detailPaneOpen = open;
    this.detailClosing = !open;
    this.detailClosingLauncher = !open && fromLauncher;
    const target = open ? 1 : 0;
    this.getUIContext().animateTo({ duration: open ? Motion.medium : Motion.fast, curve: Motion.standard,
      onFinish: () => { if (token === this.detailAnim) { this.detailClosing = false; this.detailClosingLauncher = false; } } }, () => {
        this.detailReveal = target;
      });
  }

  // A tab is available while its panel owns content. A preview whose conversation
  // changed keeps its order slot but leaves the strip until that chat returns.
  private detailTabPresent(tab: string): boolean {
    if (tab === 'files') { return this.workspaceOpen; }
    if (tab === 'preview') { return this.previewVisible && this.hasPreview(); }
    if (tab === 'browser') { return this.browserExpanded && this.browser.open; }
    return false;
  }

  private detailTabsAvailable(): string[] {
    return this.detailTabs.filter((tab: string) => this.detailTabPresent(tab));
  }

  private currentDetailTab(): string {
    const available = this.detailTabsAvailable();
    if (available.includes(this.activeDetailTab)) { return this.activeDetailTab; }
    return available.length > 0 ? available[0] : '';
  }

  private detailTabVisible(tab: string): boolean {
    return this.detailPaneOpen && this.currentDetailTab() === tab;
  }

  private detailTabItems(): DetailTabItem[] {
    const items: DetailTabItem[] = [];
    for (const tab of this.detailTabsAvailable()) {
      if (tab === 'files') {
        items.push(new DetailTabItem('files', t('工作区文件'), $r('sys.symbol.folder')));
      } else if (tab === 'preview') {
        items.push(new DetailTabItem('preview', t('预览'), $r('sys.symbol.doc_text')));
      } else if (tab === 'browser') {
        const title = this.browser.title.trim();
        items.push(new DetailTabItem('browser', title.length > 0 && title !== 'about:blank' ? title : t('应用内浏览器'),
          $r('sys.symbol.connection')));
      }
    }
    return items;
  }

  private openDetailTab(tab: string): void {
    if (!this.detailTabs.includes(tab)) { this.detailTabs = this.detailTabs.concat(tab); }
    this.activeDetailTab = tab;
    this.setDetailPane(true);
    this.getUIContext().getFocusController().clearFocus();
    this.setDrawer(false);
  }

  private removeDetailTab(tab: string): void {
    const remaining = this.detailTabs.filter((item: string) => item !== tab);
    this.detailTabs = remaining;
    const available = remaining.filter((item: string) => this.detailTabPresent(item));
    if (this.activeDetailTab === tab) { this.activeDetailTab = available.length > 0 ? available[0] : ''; }
    if (available.length === 0) { this.setDetailPane(false); }
  }

  private closeDetailTab(tab: string): void {
    if (tab === 'browser') { this.closeBrowser(); return; }
    if (tab === 'preview') { this.closePreview(); return; }
    if (tab === 'files') { this.workspaceTabCloseRequest++; }
  }

  private workspaceClosed(): void {
    this.workspaceOpen = false;
    this.removeDetailTab('files');
  }

  private closePreview(): void {
    this.previewVisible = false;
    this.removeDetailTab('preview');
  }

  // The strip's add menu activates an existing tab instead of sending another
  // open request into a mounted editor.
  private addFilesTab(): void {
    if (this.detailTabPresent('files')) { this.openDetailTab('files'); return; }
    this.openFiles();
  }

  private addBrowserTab(): void {
    if (this.detailTabPresent('browser')) { this.openDetailTab('browser'); return; }
    this.openBrowser();
  }

  private toggleDetailPane(): void {
    this.getUIContext().getFocusController().clearFocus();
    if (this.detailPaneOpen) { this.setDetailPane(false, this.detailTabsAvailable().length === 0); return; }
    this.setDetailPane(true);
    const available = this.detailTabsAvailable();
    if (!available.includes(this.activeDetailTab)) { this.activeDetailTab = available.length > 0 ? available[0] : ''; }
    this.setDrawer(false);
  }

  private previewPresenceChanged(present: boolean): void {
    this.previewPresent = present;
    if (!present && !this.previewVisible) { this.previewId = ''; }
  }

  private browserPresenceChanged(present: boolean): void {
    this.browserPresent = present;
    if (!present && !this.browser.open) {
      this.browserExpanded = false;
      this.removeDetailTab('browser');
    }
    if (!present && this.browserClosing && !this.browserExpanded) { this.browserClosing = false; this.browser.close(); }
  }

  private closeBrowser(): void {
    this.browser.takeOver(); this.browserClosing = true; this.setBrowserExpanded(false);
    this.removeDetailTab('browser');
  }

  // Collapsing the phone header hides the tab without closing the browser
  // session; the chat's browser status card can bring it back as a tab.
  private hideBrowserTab(): void {
    this.browserExpanded = false;
    this.removeDetailTab('browser');
  }
  private workbench(): WorkbenchLayout {
    return new WorkbenchLayout(this.windowWidth, this.detailOpen(), !this.historyCollapsed,
      this.historyPreferredWidth, this.detailPreferredWidth);
  }

  // The rail expands the column only when it still fits; otherwise it reveals the
  // overlay drawer, so history keeps working on a narrow split-screen window.
  private toggleHistory(): void {
    if (this.workbench().expanded) { this.setHistoryCollapsed(true); }
    else if (this.workbench().canExpand) { this.setHistoryCollapsed(false); }
    else { this.setDrawer(true); }
  }

  private setHistoryCollapsed(collapsed: boolean): void {
    if (this.historyCollapsed === collapsed) { return; }
    this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard }, () => {
      this.historyCollapsed = collapsed;
    });
  }

  // One tap from the rail opens the overlay drawer with the search field focused.
  private openHistorySearch(): void {
    this.setDrawer(true);
    this.historySearchRequest++;
  }

  private beginResize(detail: boolean): void {
    this.resizeBase = detail ? this.workbench().detailWidth : this.workbench().historyWidth;
  }

  private resizeHistory(dx: number): void {
    // Growing the column must not make the docked pane impossible: unlike the
    // desktop frame there is no second track to renegotiate, so stop at the width
    // where both remaining panes keep their minima instead of collapsing mid-drag.
    const layout = this.workbench();
    const limit = layout.docked
      ? layout.width - WorkbenchLayout.CHAT_MIN - WorkbenchLayout.DETAIL_MIN : WorkbenchLayout.HISTORY_MAX;
    this.historyPreferredWidth = Math.max(WorkbenchLayout.HISTORY_MIN,
      Math.min(WorkbenchLayout.HISTORY_MAX, limit, this.resizeBase + dx));
  }

  private resizeDetail(dx: number): void {
    const layout = this.workbench();
    this.detailPreferredWidth = Math.max(WorkbenchLayout.DETAIL_MIN,
      Math.min(layout.detailMaxWidth, this.resizeBase - dx));
  }

  // Commit the clamped result so the next window resize does not replay the raw drag.
  private endResize(detail: boolean): void {
    if (detail) { this.detailPreferredWidth = this.workbench().detailWidth; }
    else { this.historyPreferredWidth = this.workbench().historyWidth; }
  }

  private windowChanged(width: number): void {
    if (width <= 0 || width === this.windowWidth) { return; }
    this.windowWidth = width;
    if (this.workbench().historyWidth > 0) {
      // Invalidate any closing animation; the same history host becomes the sidebar.
      this.drawerAnimation++; this.drawerOpen = false; this.drawerDragging = false;
      this.drawerReveal = 0; this.drawerContentActive = false;
    }
  }
  private openPreview(messageId: string, previewId: string): void {
    this.previewThreadId = this.app.active.id; this.previewMessageId = messageId; this.previewId = previewId; this.previewVisible = true;
    this.openDetailTab('preview');
  }

  onBackPress(): boolean {
    const active = this.currentDetailTab();
    if (this.detailPaneOpen && active === 'browser') {
      if (this.browser.editingAddress) { this.getUIContext().getFocusController().clearFocus(); return true; }
      if (this.browser.owner === 'user' && this.browser.userBack()) { return true; }
      this.hideBrowserTab(); return true;
    }
    if (this.drawerOpen || this.drawerDragging) {
      this.setDrawer(false);
      return true;
    }
    if (this.detailPaneOpen && active === 'preview' && this.hasPreview()) { this.closePreview(); return true; }
    if (this.detailPaneOpen && active === 'files' && this.workspaceOpen) { this.workspaceCloseRequest++; return true; }
    if (this.detailPaneOpen) { this.setDetailPane(false, this.detailTabsAvailable().length === 0); return true; }
    return false;
  }

  private setBrowserExpanded(expanded: boolean): void {
    this.getUIContext().getFocusController().clearFocus();
    if (expanded) { this.browserClosing = false; }
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
    try { this.browser.openForUser(); this.setBrowserExpanded(true); this.openDetailTab('browser'); }
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
    if (!this.app.canQueueInput || this.app.active.attachments.length >= MAX_MESSAGE_ATTACHMENTS) { throw new Error(t('当前无法添加附件，请稍后重试。')); }
    const item = await Attachments.saveBrowserAnnotation(pixel);
    await this.app.appendDraftAttachment(threadId, item, browserAnnotationText(page, note));
    this.paths.clear(); this.setDrawer(false); this.setBrowserExpanded(false);
  }

  aboutToDisappear(): void {
    this.reviewDisposed = true; this.closeReviewInvitation(); this.startupBackupDialog?.close();
    this.closeAnnouncement();
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
    if (this.workbench().expanded || !this.app.ready || (fromChat && (this.drawerOpen || event.offsetX <= 0 ||
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
    if (page === 'privacy') {
      this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('隐私政策'),
        message: t('您可以查看隐私政策，或拒绝隐私授权。'),
        primaryButton: { value: t('查看'), action: () => { this.openSupport('view-privacy'); } },
        secondaryButton: { value: t('拒绝'), fontColor: $r('app.color.danger'),
          action: () => { this.openSupport('revoke-privacy'); } } });
      return;
    }
    if (page === 'revoke-privacy') {
      this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('拒绝隐私政策？'),
        message: t('拒绝后将撤回隐私授权，停止当前对话并退出应用。下次打开时，需重新同意才能继续使用。已有会话、文件和设置会保留。'),
        primaryButton: { value: t('取消'), action: () => {} },
        secondaryButton: { value: t('拒绝并退出'), fontColor: $r('app.color.danger'), action: () => {
          try { this.privacy.revokeConsent(); }
          catch (error) {
            this.getUIContext().getPromptAction().showToast({ message: (error as Error).message });
          }
        } } });
      return;
    }
    if (page === 'view-privacy') {
      try { await this.privacy.openPolicy(this.getUIContext().getHostContext() as common.UIAbilityContext); }
      catch (error) {
        this.getUIContext().getPromptAction().showToast({ message: t('无法打开托管隐私政策，请重试。') });
      }
      return;
    }
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
      Diagnostics.log('info', 'review', 'request_completed');
      // Stop automatic requests after accepting the system flow, even if the user dismissed it.
      // This is invitation history, not proof that a rating was submitted. Manual access stays available.
      try { this.reviewPreferences().stopInvitations(); }
      catch (error) { this.reviewSaveFailed(error as Error); }
    } catch (error) {
      const failure = error as BusinessError;
      Diagnostics.log('error', 'review', 'request_failed', undefined, failure);
      if (failure.code === 1021500007 || failure.code === 1021500009) {
        try { this.reviewPreferences().stopInvitations(); }
        catch (storageError) { this.reviewSaveFailed(storageError as Error); }
        this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface,
          message: t('你已评价过此应用，感谢反馈。') });
        return;
      }
      const detail = failure.code ? failure.code + ' · ' + failure.message : failure.message;
      this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('评分和评论'),
        message: t('暂时无法打开评分和评论，请稍后重试。错误：{0}', [detail]),
        confirm: { value: t('关闭'), action: () => {} } });
    } finally { this.ratingOpen = false; }
  }

  private openFiles(path: string = ''): void {
    this.getUIContext().getFocusController().clearFocus();
    this.workspacePath = path; this.workspaceRequest++; this.workspaceOpen = true;
    this.openDetailTab('files');
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

  private openConversationShare(): void {
    if (!this.app.ready || this.app.busy || !this.app.active.messages.length) { return; }
    const snapshot = this.app.exportSnapshot();
    const data: ConversationShareData = {
      thread: snapshot.threads.find((thread) => thread.id === this.app.active.id)!,
      profiles: snapshot.providerProfiles || []
    };
    data.thread.messages = sharingMessages(data.thread.messages);
    if (!data.thread.messages.length) {
      this.getUIContext().getPromptAction().showToast({ message: t('暂无可分享的正文') });
      return;
    }
    this.paths.pushPath({ name: 'share-conversation', param: data });
  }

  // Conversation-level actions live in the header; the composer "+" sheet holds per-message inputs.
  @Builder
  toolScopeSheet() {
    ToolScopePanel({ app: this.app, thread: this.app.active })
  }

  @Builder
  moreMenuHeader() {
    materialMenuHeader(t('本对话'))
  }

  @Builder
  moreMenuContent(icon: Resource, label: string, image: boolean = false) {
    materialMenuContent({ label: label, icon: icon, image: image })
  }

  @Builder
  moreMenu() {
    Menu() {
      MenuItemGroup({ header: this.moreMenuHeader }) {
        MenuItem(() => this.moreMenuContent($r('sys.symbol.wrench_and_screwdriver'),
          t('工具范围：{0}', [agentModeName(this.app.active.agentMode)]))).id('open-tool-scope')
          .enabled(this.app.ready && !this.app.busy && !this.app.active.archived && this.app.saveError.length === 0)
          .onClick(() => { this.showToolScope = true; })
        MenuItem(() => this.moreMenuContent($r('sys.symbol.folder'), t('工作区文件')))
          .enabled(!this.app.busy).onClick(() => this.openFiles())
        MenuItem(() => this.moreMenuContent($r('sys.symbol.connection'), t('应用内浏览器')))
          .id('open-browser').enabled(this.app.ready && !this.browser.permissionSaving && this.app.saveError.length === 0)
          .onClick(() => this.openBrowser())
        MenuItem(() => this.moreMenuContent($r('sys.symbol.rectangle_stack'), t('分支关系')))
          .enabled(!this.app.busy).onClick(() => this.paths.pushPath({ name: 'branches' }))
        MenuItem(() => this.moreMenuContent($r('app.media.message_branch'), t('创建分支'), true))
          .enabled(!this.app.busy && this.app.saveError.length === 0 && this.app.active.messages.length > 0)
          .onClick(() => this.fork())
        MenuItem(() => this.moreMenuContent($r('sys.symbol.share'), t('分享会话')))
          .id('share-conversation').enabled(this.app.ready && !this.app.busy && this.app.active.messages.length > 0)
          .onClick(() => this.openConversationShare())
      }
      if (this.app.productivity.options?.miniAppsEnabled === true) {
        MenuItem(() => this.moreMenuContent($r('sys.symbol.rectangle_stack'), t('小程序')))
          .id('open-mini-apps-menu').enabled(this.app.ready).onClick(() => this.paths.pushPath({ name: 'mini-apps' }))
      }
      MenuItem(() => this.moreMenuContent($r('sys.symbol.gearshape'), t('设置')))
        .onClick(() => this.openSettings())
    }
  }

  @Builder
  destination(name: string, param: Object) {
    if (name === 'onboarding') {
      NavDestination() {
        OnboardingPanel({ app: this.app, active: this.onboardingActive, configured: this.app.configured,
          connectedPreset: this.currentProviderPreset(), busy: this.app.busy, account: this.account,
          onFinish: (action: string, prompt: string) => this.finishOnboarding(action, prompt),
          onConnect: (preset: string) => this.connectOnboardingProvider(preset),
          onLegal: (page: string) => { this.openSupport(page); } })
      }.hideTitleBar(true).backgroundColor($r('app.color.page_background'))
        .onBackPressed(() => {
          this.finishOnboarding('skip', '').catch((error: Error) => {
            this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: error.message });
          });
          return true;
        })
        .onShown(() => { this.onboardingActive = true; })
        .onHidden(() => { this.onboardingActive = false; })
    } else if (name === 'mini-apps') {
      NavDestination() {
        if (this.app.productivity.options?.miniAppsEnabled === true) {
          MiniAppsPanel({ app: this.app, onChat: () => this.revealChat(), addRequest: this.miniAppAddRequest,
            previewRevision: this.app.active.id + ':' + this.app.active.latestPreviewIds.join(','),
            onAddAvailable: (available: boolean) => { this.miniAppAddAvailable = available; } })
        } else { Text(t('请先在设置的实验室中开启小程序。')) }
      }
        .title(t('小程序'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
        .menus(this.miniAppAddAvailable ? [{ value: t('从当前会话的预览添加'), symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
          isEnabled: !this.app.busy, action: () => { this.miniAppAddRequest++; } }] : [])
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
    } else if (name === 'storage') {
      NavDestination() {
        StoragePanel({ app: this.app, onCategory: (id: string) => { this.paths.pushPath({ name: 'storage-category', param: id }); } })
      }.title(t('存储空间'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'storage-category') {
      NavDestination() {
        StorageCategoryPanel({ app: this.app, category: param as string })
      }.title(t(storageCategoryKey(param as string)), { systemMaterial: this.appearance.control })
        .backgroundColor($r('app.color.page_background'))
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
      NavDestination() {
        SearchSettingsPanel({ app: this.app, onEdit: (request: SearchProviderRoute, onReturn: (draft?: SearchEditorDraft) => void) => {
          this.paths.pushPath({ name: 'search-provider', param: request,
            onPop: (info: PopInfo) => { onReturn(info.result as SearchEditorDraft | undefined); } });
        } })
      }.title(t('搜索服务'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'search-provider') {
      NavDestination() {
        SearchProviderPanel({ app: this.app, request: param as SearchProviderRoute,
          onDone: (draft?: SearchEditorDraft) => { this.paths.pop(draft); } })
      }.title(searchProviderName((param as SearchProviderRoute).provider), { systemMaterial: this.appearance.control })
        .backgroundColor($r('app.color.page_background'))
    } else if (name === 'share-conversation') {
      ConversationSharePanel({ data: param as ConversationShareData })
    } else if (name === 'files') {
      WorkspacePanel({ app: this.app, initialPath: (param as string) || '' })
    } else if (name === 'account') {
      NavDestination() {
        HuaweiAccountPanel({ account: this.account, taskBusy: this.app.sharedBusy, onSupport: (page: string) => this.openSupport(page) })
      }.title(t('华为账号'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'laboratory') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings, account: this.account, browser: this.browser, laboratoryOnly: true })
      }.title(t('实验室'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'settings') {
      NavDestination() {
        SettingsPanel({ app: this.app, settings: this.app.settings, account: this.account,
          onAccount: () => { this.paths.pushPath({ name: 'account' }); },
          browser: this.browser,
          onAddProvider: () => { this.paths.pushPath({ name: 'provider-presets' }); },
          onUsage: () => { this.paths.pushPath({ name: 'usage' }); },
          onStorage: () => { this.paths.pushPath({ name: 'storage' }); },
          onModels: () => { this.paths.pushPath({ name: 'model-settings' }); },
          onSearch: () => { this.paths.pushPath({ name: 'search-settings' }); },
          onLaboratory: () => { this.paths.pushPath({ name: 'laboratory' }); },
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
        SettingsPanel({ app: this.app, settings: this.app.settings, account: this.account, browser: this.browser, presetsOnly: true,
          onEditProvider: (_id: string, preset: string) => {
            if (this.app.beginProvider(preset, '')) { this.paths.replacePath({ name: 'provider' }); }
          } })
      }.title(t('添加模型服务'), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'support') {
      NavDestination() {
        SupportPanel({ page: param as string,
          onOpen: (page: string) => this.openSupport(page), onClose: () => { this.paths.pop(); } })
      }.title(supportTitle(param as string), { systemMaterial: this.appearance.control })
        .hideTitleBar((param as string) === 'feedback').backgroundColor($r('app.color.page_background'))
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
        ProviderEditorPanel({ app: this.app, editor: this.app.providerEditor, active: this.providerEditorActive, onSaved: () => { this.paths.pop(); },
          onModels: (error: string) => { this.paths.pushPath({ name: 'provider-models', param: error }); },
          onDiscovered: (models: string[]) => { this.paths.pushPath({ name: 'provider-discovery', param: models }); } })
      }.title(this.app.providerEditor.id.length > 0 ? t("编辑服务") : t("添加服务"), { systemMaterial: this.appearance.control }).backgroundColor($r('app.color.page_background'))
        .onWillShow(() => { this.providerEditorActive = true; })
        .onWillHide(() => { this.providerEditorActive = false; })
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
    if (this.windowWidth >= 840) {
      // On the plain tablet title surface, API-26 light-sense material erases
      // the control fill; keep an opaque tint and reserve material for phones.
      Row({ space: 4 }) {
        if (this.workbench().historyWidth === 0) {
          IconButton({ icon: $r('sys.symbol.line_3_horizontal'), label: t('对话列表'), compId: 'open-history',
            fill: $r('app.color.surface_variant'),
            disabled: !this.app.ready, onTap: () => this.setDrawer(true) })
        }
        Text(this.app.active.messages.length > 0 ? this.app.active.displayTitle : '').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(19).fontColor([$r('app.color.text_secondary')])
        }.id('workbench-chat-more').width(44).height(44).borderRadius(22)
          .backgroundColor($r('app.color.surface_variant'))
          .accessibilityText(t('更多操作'))
          .enabled(this.app.ready).bindMenu(this.moreMenu, { systemMaterial: this.appearance.menu, mask: false })
        IconButton({ icon: this.detailPaneOpen ? $r('sys.symbol.close_sidebar') : $r('sys.symbol.open_sidebar'),
          label: this.detailPaneOpen ? t('关闭侧栏') : t('打开侧栏'), compId: 'workbench-toggle-detail',
          fill: $r('app.color.surface_variant'),
          disabled: !this.app.ready, onTap: () => this.toggleDetailPane() })
      }.width('100%').height(CHAT_HEADER_HEIGHT).padding({ left: 12, right: 12 })
        .hitTestBehavior(HitTestMode.Transparent)
    } else { this.phoneHeader() }
  }

  @Builder
  phoneHeader() {
    Stack() {
      Column().id('chat-header-backdrop').width('100%').height(CHAT_HEADER_HEIGHT)
        .backgroundEffect({ radius: 12, color: $r('app.color.chat_header_background') })
        .translate({ y: -CHAT_HEADER_HEIGHT * this.headerProgress }).opacity(1 - this.headerProgress)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    Row({ space: 4 }) {
      if (this.workbench().historyWidth === 0) {
      IconButton({ icon: $r('sys.symbol.line_3_horizontal'), label: t("对话列表"), compId: 'open-history',
        material: this.appearance.control, tint: $r('sys.color.font_primary'),
        disabled: !this.app.ready, onTap: () => this.setDrawer(true) })
      }
      if (this.windowWidth >= 840) {
        IconButton({ icon: $r('sys.symbol.folder'), label: t('工作区文件'), compId: 'workbench-open-files',
          disabled: !this.app.ready, onTap: () => this.openFiles() })
      }
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
      }.id('chat-more').width(44).height(44).borderRadius(22).backgroundColor(this.appearance.controlBackground)
      .border({ width: this.appearance.materialAvailable ? 0 : 0.5, color: $r('app.color.divider') })
      .attributeModifier(systemMaterialAttribute<ButtonAttribute>(this.appearance.control)).accessibilityText(t("更多操作"))
      .enabled(this.app.ready).bindMenu(this.moreMenu, {
        systemMaterial: this.appearance.menu, mask: false })
      IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t("新建对话"), compId: 'new-chat',
        material: this.appearance.control, tint: $r('sys.color.font_primary'),
        disabled: !this.app.canNavigate,
        onTap: () => { this.createChat(); } })
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
        .opacity(this.workbench().expanded ? 0 : this.drawerReveal)
        .hitTestBehavior(this.workbench().expanded ? HitTestMode.None : HitTestMode.Default)
        .onClick(() => this.setDrawer(false))
      Stack() {
        Column().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
          .borderRadius({ topRight: this.workbench().expanded ? 0 : 20, bottomRight: this.workbench().expanded ? 0 : 20 })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        ThreadList({ app: this.app, workbench: this.windowWidth >= 840,
          onMiniApps: () => { this.setDrawer(false); this.paths.pushPath({ name: 'mini-apps' }); },
          collapseHistory: this.workbench().expanded, searchRequest: this.historySearchRequest,
          onCollapseHistory: () => this.setHistoryCollapsed(true),
          onNewChat: () => { this.createChat(); this.setDrawer(false); }, onTools: () => { this.setDrawer(false); this.openTools('memory'); },
          active: !this.onboardingActive && (this.workbench().expanded || this.drawerContentActive),
          onSelected: () => this.revealChat(), onFiles: () => { this.setDrawer(false); this.openFiles(); }, onSettings: () => {
          this.setDrawer(false);
          this.openSettings();
        } })
      }
      .width(this.workbench().expanded ? this.workbench().historyWidth : '84%').constraintSize({ maxWidth: DRAWER_MAX_WIDTH }).height('100%')
      .id('history-drawer')
      .translate({ x: this.workbench().expanded ? 0 : (this.drawerReveal - 1) * this.drawerWidth })
      .onAreaChange((_old: Area, next: Area) => { this.drawerWidth = Math.max(1, next.width as number); })
    }.width(this.workbench().expanded ? this.workbench().historyWidth : '100%').height('100%')
    .position({ x: 0, y: 0 })
    .border({ width: { right: this.workbench().expanded ? 0.5 : 0 }, color: $r('app.color.divider') })
    .hitTestBehavior(this.workbench().expanded || this.drawerOpen || this.drawerDragging ? HitTestMode.Default : HitTestMode.None)
    .enabled(this.workbench().expanded || this.drawerOpen || this.drawerDragging)
    .accessibilityLevel(this.workbench().expanded || this.drawerOpen || this.drawerDragging ? 'auto' : 'no-hide-descendants')
    .gesture(PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Horizontal, distance: 8 })
      .onActionStart((event: GestureEvent) => this.startDrawerDrag(event))
      .onActionUpdate((event: GestureEvent) => this.updateDrawerDrag(event))
      .onActionEnd((event: GestureEvent) => this.endDrawerDrag(event))
      .onActionCancel(() => this.cancelDrawerDrag()))
  }

  build() {
    Stack() {
      if (!this.privacyAllowed) {
        Column({ space: Space.lg }) {
          Text('Tinybot').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          if (this.privacy.simulatorDebug) {
            Text(t('模拟器调试隐私说明')).id('debug-privacy-title')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            Text(t('此入口仅用于 Debug 包的模拟器调试。同意仅在本次运行有效，不代表已完成华为系统隐私授权。'))
              .fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
            Text(t('进入后会初始化账号、会话和诊断等服务。使用在线功能时，对话、附件及必要信息可能发送给配置的服务商，请仅使用测试数据。'))
              .fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
            if (this.privacy.error) {
              Text(this.privacy.error).id('privacy-status').fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
            }
            Button(t('隐私政策')).id('debug-privacy-policy').attributeModifier(Btn.tonal)
              .onClick(() => this.openSupport('privacy'))
            Button(t('同意并进入调试')).id('accept-debug-privacy').attributeModifier(Btn.primary)
              .onClick(() => this.privacy.acceptDebugConsent())
            Button(t('退出应用')).id('exit-debug-privacy').attributeModifier(Btn.tonal).onClick(() => this.privacy.exit())
          } else if (this.privacy.error) {
            Text(this.privacy.error).id('privacy-status').fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
            Button(t('重试')).id('retry-privacy').attributeModifier(Btn.primary)
              .enabled(!this.privacy.busy).onClick(() => this.privacy.requestConsent())
            Button(t('退出应用')).id('exit-privacy').attributeModifier(Btn.tonal).onClick(() => this.privacy.exit())
          }
        }.padding(Space.xl).width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.page_background'))
      } else {
      ForEach([this.locale], (_locale: string) => {
    Stack() {
    Row() {
    if (this.workbench().rail) {
      HistoryRail({ active: this.app.ready, filesActive: this.detailPaneOpen && this.currentDetailTab() === 'files',
        onExpand: () => this.toggleHistory(),
        onNewChat: () => { this.createChat(); this.setDrawer(false); },
        onSearch: () => this.openHistorySearch(),
        onFiles: () => this.openFiles(),
        onTools: () => this.openTools('memory'),
        onSettings: () => this.openSettings() })
        .width(this.workbench().historyWidth).height('100%')
    } else {
      Column().width(this.workbench().historyWidth).height('100%')
    }
    Navigation(this.paths) {
      Stack() {
        // Render the capture card at chat width behind the opaque page.
        PreviewCaptureHost()
        Column().width('100%').height('100%').backgroundColor(this.windowWidth >= 840 ? $r('app.color.surface') : $r('app.color.page_background'))
          .expandSafeArea([SafeAreaType.SYSTEM], this.windowWidth >= 840 ? [] : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        Column() {
          if (this.app.ready) {
            ChatPanel({ app: this.app, thread: this.app.active, workbench: this.windowWidth >= 840,
                onToolScope: () => { this.showToolScope = true; }, approval: this.approval, browser: this.browser, account: this.account,
                onAccount: () => { this.paths.pushPath({ name: 'account' }); },
                onBrowser: () => { this.setBrowserExpanded(true); this.openDetailTab('browser'); },
                onSettings: () => this.openSettings(),
                topInset: this.windowWidth >= 840 ? 0 : CHAT_HEADER_HEIGHT,
                onHeaderProgress: (progress: number): void => { this.headerProgress = progress; },
                voiceRequest: this.voiceRequest, onVoiceShortcutConsumed: () => { this.voiceRequest = ''; },
                activeThreadId: this.app.active.id, speechEnabled: this.chatVisible && !this.drawerOpen && !this.drawerDragging && (!this.detailOpen() || this.workbench().docked),
                onHistoryDragStart: (event: GestureEvent) => this.startDrawerDrag(event, true),
                onHistoryDragUpdate: (event: GestureEvent) => this.updateDrawerDrag(event),
                onHistoryDragEnd: (event: GestureEvent) => this.endDrawerDrag(event),
                onHistoryDragCancel: () => this.cancelDrawerDrag(),
                onFiles: () => this.openFiles(), onOpenFile: (path: string) => this.openFiles(path),
                previewInspectable: this.windowWidth >= 840, inspectedPreviewId: this.hasPreview() ? this.previewId : '',
                onInspectPreview: (messageId: string, previewId: string) => this.openPreview(messageId, previewId),
                onTools: (tab: string) => this.openTools(tab) })
              .width('100%').constraintSize({ maxWidth: 800 }).layoutWeight(1)
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
    .backgroundColor(this.windowWidth >= 840 ? $r('app.color.surface') : $r('app.color.page_background'))
    // Native button materials only work inside the actual navigation title bar.
    .title({ builder: this.header, height: CHAT_HEADER_HEIGHT }, {
      barStyle: this.windowWidth >= 840 ? BarStyle.STANDARD : BarStyle.STACK,
      backgroundColor: this.windowWidth >= 840 ? $r('app.color.surface') : Color.Transparent,
      backgroundEffect: { radius: 0, color: Color.Transparent }
    })
    .hideBackButton(true).titleMode(NavigationTitleMode.Mini).hideToolBar(true).mode(NavigationMode.Stack)
    .onNavBarStateChange((visible: boolean) => { this.chatVisible = visible; if (visible) { this.offerAnnouncement(); } })
    .navDestination(this.destination).layoutWeight(1).height(this.windowWidth >= 840 ? 'calc(100% - 12vp)' : '100%')
    .margin({ top: this.windowWidth >= 840 ? 6 : 0, bottom: this.windowWidth >= 840 ? 6 : 0,
      right: this.windowWidth >= 840 && !this.workbench().docked ? 6 : 0 })
    .borderRadius(this.windowWidth >= 840 ? Radius.xl : 0).clip(this.windowWidth >= 840)
    Column().width(this.workbench().docked ? this.detailGeometry().detailWidth * this.detailReveal : 0).height('100%')
    }.width('100%').height('100%')
    // Cover both the navigation title bar and content, keeping the measured drawer mounted.
    if (this.app.ready) {
      this.drawer()
    }
    // Draggable seams sit above the drawer layer: the persistent column and the
    // overlay drawer never coexist, so a grip here can never steal a list tap.
    if (this.app.ready && this.workbench().expanded) {
      PaneDivider({ label: t('调整会话栏宽度'),
        onResizeStart: () => this.beginResize(false),
        onResize: (dx: number) => this.resizeHistory(dx),
        onResizeEnd: () => this.endResize(false) })
        .width(12).height('calc(100% - 12vp)')
        .position({ x: this.workbench().historyWidth - 4, y: 6 })
    }
    if (this.app.ready && this.workbench().docked && this.detailReveal >= 1 && !this.drawerOpen && !this.drawerDragging && this.drawerReveal <= 0) {
      PaneDivider({ label: t('调整侧区宽度'),
        onResizeStart: () => this.beginResize(true),
        onResize: (dx: number) => this.resizeDetail(dx),
        onResizeEnd: () => this.endResize(true) })
        .width(12).height('calc(100% - 12vp)')
        .position({ x: this.detailGeometry().detailX - 8, y: 6 })
    }
    }.width('100%').height('100%')
      }, (locale: string) => locale)
      // These hosts keep their position in the tree across all width breakpoints.
      // Only their geometry changes; resizing never reinitializes the session or editor.
      // One docked surface owns the strip and the panel bodies. The bodies keep
      // their position in the tree across tab switches so editors, previews and
      // the Web host keep their state; only the tab strip decides which is shown.
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          if (this.workbench().docked && this.detailOpen() && this.detailTabsAvailable().length > 0) {
            DetailTabs({ tabs: this.detailTabItems(), active: this.currentDetailTab(),
              onSelect: (id: string) => { this.activeDetailTab = id; },
              onClose: (id: string) => this.closeDetailTab(id),
              onAddFiles: () => this.addFilesTab(),
              onAddBrowser: () => this.addBrowserTab(),
              onCollapse: () => { this.setDetailPane(false); } })
          }
          Stack() {
            AnimatedPage({ visible: this.detailTabVisible('files'), retained: this.workspaceOpen,
              onPresenceChanged: (present: boolean) => { this.workspacePresent = present; } }) {
              WorkspacePanel({ app: this.app, embedded: true, tabbed: this.workbench().docked,
                initialPath: this.workspacePath, requestId: this.workspaceRequest,
                closeRequest: this.workspaceCloseRequest, tabCloseRequest: this.workspaceTabCloseRequest,
                onClose: () => this.workspaceClosed() })
            }
            AnimatedPage({ visible: this.detailTabVisible('preview') && this.hasPreview(),
              retained: this.previewVisible && this.hasPreview(),
              onPresenceChanged: (present: boolean) => this.previewPresenceChanged(present) }) {
              PreviewPanel({ app: this.app, threadId: this.previewThreadId, messageId: this.previewMessageId,
                previewId: this.previewId, tabbed: this.workbench().docked, onClose: () => this.closePreview() })
            }
            // The Web host stays mounted even when its tab is closed: the browser
            // session opens against an attached view, and reopening a tab reuses it.
            AnimatedPage({ visible: this.detailTabVisible('browser'), retained: true,
              vertical: this.windowWidth < 840, onPresenceChanged: (present: boolean) => this.browserPresenceChanged(present) }) {
              BrowserPanel({ browser: this.browser, expanded: this.detailTabVisible('browser'), presented: this.browserPresent,
                onPresent: () => { this.setBrowserExpanded(true); this.openDetailTab('browser'); },
                tabbed: this.workbench().docked, threadId: this.app.active.id,
                canAnnotate: this.app.canQueueInput && this.app.active.attachments.length < MAX_MESSAGE_ATTACHMENTS,
                onAnnotation: (threadId: string, pixel: image.PixelMap, page: AnnotationPage, note: string) => this.addBrowserAnnotation(threadId, pixel, page, note),
                onSettings: () => { this.hideBrowserTab(); this.openSettings(); },
                onClose: () => this.closeBrowser(), onDismiss: () => this.hideBrowserTab() })
            }
            AnimatedPage({ visible: this.workbench().docked &&
              ((this.detailPaneOpen && this.detailTabsAvailable().length === 0) ||
                (this.detailClosing && this.detailClosingLauncher)) }) {
              DetailLauncher({ onFiles: () => this.openFiles(), onBrowser: () => this.openBrowser(),
                onClose: () => { this.setDetailPane(false, true); } })
            }
          }.width('100%').layoutWeight(1)
        }.width(this.workbench().docked ? this.detailGeometry().detailWidth - 6 : '100%').height('100%')
        .backgroundColor(this.detailOpen() ? $r('app.color.surface') : Color.Transparent)
      }.width(this.workbench().docked ? Math.max(0, this.detailGeometry().detailWidth * this.detailReveal - 6) : '100%')
        .height(this.windowWidth >= 840 ? 'calc(100% - 12vp)' : '100%')
        .borderRadius(this.windowWidth >= 840 ? Radius.xl : 0).clip(true)
        .position({ x: this.workbench().docked ? this.windowWidth - this.detailGeometry().detailWidth * this.detailReveal : 0,
          y: this.windowWidth >= 840 ? 6 : 0 })
        .hitTestBehavior(this.detailOpen() ? HitTestMode.Default : HitTestMode.None)
        .enabled(this.detailOpen())
        // A closed host keeps its retained bodies mounted but must not lay a
        // full-window transparent layer over the page.
        .visibility(this.detailOpen() ? Visibility.Visible : Visibility.Hidden)
        .accessibilityLevel(this.detailOpen() ? 'auto' : 'no-hide-descendants')
        .border({ width: { left: this.workbench().docked ? 0.5 : 0 }, color: $r('app.color.divider') })
      }
    }.width('100%').height('100%')
    .backgroundColor($r('app.color.page_background'))
    .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.cancelReviewOffer(); } })
    .onAreaChange((_old: Area, area: Area) => this.windowChanged(Number(area.width)))
    .bindSheet($$this.showToolScope, this.toolScopeSheet(), { title: { title: t('工具范围') },
      height: this.app.active.agentMode === 'custom' ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
      detents: this.app.active.agentMode === 'custom' ? [SheetSize.LARGE] : undefined,
      preferType: this.windowWidth >= 840 ? SheetType.CENTER : SheetType.BOTTOM,
      maskColor: '#33000000',
      dragBar: true, backgroundColor: $r('app.color.page_background'), systemMaterial: this.appearance.readingSurface })
  }
}
