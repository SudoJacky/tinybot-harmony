import { BrowserPreview } from '../model/BrowserPreview';
import { ProviderEffects } from './providers/Provider';
import { PresentTools } from './PresentTools';
import { PreviewTools } from './PreviewTools';
import { MiniApps } from './MiniApps';
import { MiniAppTools } from './MiniAppTools';
import { PreviewCapture } from './PreviewCapture';
import { savePreviewRepair } from './PreviewRecovery';
import { WebSearchTools } from './WebSearchTools';
import { NativeSearchTransport } from './NativeSearchTransport';
import { BrowserSearchTransport } from './BrowserSearchTransport';
import { isSupportedSearchProvider } from '../model/WebSearch';
import { isSupportedProtocol } from '../model/ProviderEndpoint';
import { ProductivityData, Attachment, McpServer } from '../model/Productivity';
import { LiveResources, McpRequest } from '../model/ResourceManagement';
import { SkillData } from '../model/Skills';
import { common } from '@kit.AbilityKit';
import { prepareNativeMcp } from './NativeResourceSetup';
import { McpClient } from './McpClient';
import { SkillInstaller } from './SkillInstaller';
import { CodeExecutionTools } from './CodeExecutionTools';
import { NativeCodeExecutor } from './NativeCodeExecutor';
import { NativeOrchestrationExecutor } from './NativeOrchestrationExecutor';
import { WebUiPreflight } from './WebUiPreflight';
import { InteractionTools } from './InteractionTools';
import { UsageLedger } from './UsageLedger';
import { UsageRecorder, UsageToolActivity, RequestUsage } from '../model/Usage';
import { ModelMessage, ContextDiagnostics } from '../model/Agent';
import { Cancellation } from './Cancellation';
import { RuleTools } from './RuleTools';
import { McpTools } from './McpTools';
import { ToolApproval } from './ToolApproval';
import { BrowserSession } from './BrowserSession';
import { BrowserTools } from './BrowserTools';
import { Attachments } from './Attachments';
import { AttachmentTools } from './AttachmentTools';
import { util } from '@kit.ArkTS';
import { Diagnostics } from '../model/Diagnostics';
import { LogFields } from '../model/DiagnosticLog';
import { ConversationStore } from '../model/ConversationStore';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ExtensionSettings } from '../model/Skills';
import { AgentRuntime } from './AgentRuntime';
import { AgentTools } from './AgentLoop';
import { CredentialStore } from './CredentialStore';
import { SessionResources } from './SessionContracts';
import { ProjectData } from '../model/Project';
import { SharedFolder } from '../model/SharedFolders';
import { ProjectFolderAccess } from './ProjectFolderAccess';
import { SessionService } from './SessionService';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { WorkspaceTools } from './WorkspaceTools';
import { nativeWorkspaceDiffs } from './NativeWorkspaceDiff';
import { NativeWebTransport } from './NativeWebTransport';
import { WebTools } from './WebTools';
import { SkillTools } from './SkillTools';
import { ToolSet } from './ToolSet';
import { profileProvider } from './providers/DefaultProviders';
import { ProviderRegistry } from './providers/ProviderRegistry';
import { huaweiAccount } from './HuaweiAccount';
import { backgroundGeneration } from './BackgroundGeneration';
import { completionNotifications } from './CompletionNotifications';

class NativeProviderEffects implements ProviderEffects {
  hydrate(messages: ModelMessage[]): Promise<ModelMessage[]> { return Attachments.hydrate(messages); }
  recordUsage(record: RequestUsage): void { UsageLedger.record(record); }
}

class NativeUsageRecorder implements UsageRecorder {
  recordTool(id: string, activity: UsageToolActivity): void { UsageLedger.recordTool(id, activity); }
  recordContext(id: string, diagnostics: ContextDiagnostics): void {
    if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'context', 'inspected', { sessionId: id, tokens: diagnostics.tokens, budget: diagnostics.inputBudget, tools: diagnostics.toolTokens, messages: diagnostics.historyTokens }); }
  }
}

export class NativeSessionResources implements SessionResources {
  authorizeGeneration(): Promise<void> { return huaweiAccount.requireLogin(); }
  async prepareGeneration(): Promise<void> {
    if (this.context) { await completionNotifications.prepare(); await backgroundGeneration.beginTurn(); }
  }
  private workspaces: WorkspaceStore;
  private miniApps: MiniApps;
  private providers: ProviderRegistry;
  private approval: ToolApproval;
  private browser?: BrowserSession;
  private profiles: ProviderProfile[] = [];
  private context?: common.UIAbilityContext;
  constructor(workspaceFilesDir: string, providers: ProviderRegistry, approval: ToolApproval, context?: common.UIAbilityContext, browser?: BrowserSession) {
    this.browser = browser;
    this.miniApps = new MiniApps(workspaceFilesDir);
    this.context = context;
    this.workspaces = new WorkspaceStore(workspaceFilesDir); this.providers = providers; this.approval = approval;
  }
  createId(): string { return util.generateRandomUUID(); }
  recoverUi(threadId: string, content: string, error: Error, cancellation: Cancellation, workspaceId?: string): Promise<string> {
    return savePreviewRepair(new NativeWorkspaceFiles(this.workspaces.pathFor(workspaceId || threadId)),
      this.createId(), content, error, cancellation);
  }
  ensureWorkspace(id: string, workspaceId?: string): Promise<void> {
    return workspaceId ? this.workspaces.requireWorkspace(workspaceId) : this.workspaces.ensureThread(id);
  }
  async prepareAttachments(items: Attachment[], threadId: string, workspaceId?: string): Promise<Attachment[]> {
    await this.ensureWorkspace(threadId, workspaceId);
    return Attachments.inWorkspace(items, workspaceId || threadId);
  }
  persistProjectFolders(folders: SharedFolder[]): Promise<void> { return ProjectFolderAccess.persist(folders); }
  revokeProjectFolders(folders: SharedFolder[]): Promise<void> { return ProjectFolderAccess.revoke(folders); }
  activateProjectFolders(projects: ProjectData[]): Promise<void> { return ProjectFolderAccess.activateAll(projects); }
  tools(id: string, extensions: ExtensionSettings, selected: string, productivity?: ProductivityData, attachments: Attachment[] = [], live?: LiveResources, workspaceId?: string, project?: ProjectData, resolvePreview?: (previewId: string) => BrowserPreview): AgentTools {
    const root = this.workspaces.pathFor(workspaceId || id);
    const files = new NativeWorkspaceFiles(root, project?.sharedFolders || []);
    const groups: AgentTools[] = [new WorkspaceTools(files, nativeWorkspaceDiffs), new AttachmentTools(attachments),
      new SkillTools(extensions.skills, selected, live ? () => live.skills() : undefined), new InteractionTools(this.approval)];
    groups.push(new CodeExecutionTools(new NativeCodeExecutor()));
    groups.push(new MiniAppTools(this.miniApps, workspaceId || id, id, files,
      (page, storage, cancellation) => WebUiPreflight.validateMiniApp(page, storage, cancellation), productivity?.options?.miniAppsEnabled === true));
    groups.push(new PresentTools((path: string) => files.checkedPath(path)));
    groups.push(new PreviewTools(files, (content, cancellation) => WebUiPreflight.validate(content, cancellation),
      (content, cancellation) => PreviewCapture.capture(content, cancellation)));
    if (extensions.webEnabled) { groups.push(new WebTools(new NativeWebTransport())); }
    if (this.browser) { groups.push(new BrowserTools(this.browser, id, productivity?.options?.readOnly === true, resolvePreview)); }
    const search = productivity?.options?.search;
    if (extensions.webEnabled && search?.enabled && isSupportedSearchProvider(search.provider)) {
      if (search.provider === 'bing-browser') {
        if (this.browser?.policy !== 'disabled') { groups.push(new WebSearchTools(new BrowserSearchTransport(this.browser, id), 'sequential')); }
      } else {
        groups.push(new WebSearchTools(new NativeSearchTransport(search, new CredentialStore(), id, (record) => UsageLedger.record(record), () => this.profiles)));
      }
    }
    if (productivity) { groups.push(new McpTools(productivity.servers, this.approval, (server) => new McpClient(server), live ? () => live.servers() : undefined)); }
    return new RuleTools(new ToolSet(groups), productivity?.options?.readOnly === true);
  }
  async afterTask(threadId: string, messageId: string, content: string, workspaceId?: string): Promise<void> {
    await new NativeWorkspaceFiles(this.workspaces.pathFor(workspaceId || threadId)).write('任务结果/' + messageId + '.md', content, new Cancellation());
  }
  configureProviders(profiles: ProviderProfile[]): void {
    this.profiles = JSON.parse(JSON.stringify(profiles)) as ProviderProfile[];
    for (const info of this.providers.list()) { this.providers.unregister(info.id); }
    for (const profile of profiles) {
      if (isSupportedProtocol(profile.protocol)) { this.providers.register(profileProvider(profile, new NativeProviderEffects())); }
    }
  }
  reportError(event: string, error: Error | string, fields?: LogFields): void { Diagnostics.log('error', 'session', event, fields, error); }
  reportMemory(event: string, fields?: LogFields): void { Diagnostics.log('info', 'memory', event, fields); }
  reportResources(event: string, fields?: LogFields): void { Diagnostics.log('info', 'resources', event, fields); }
  installSkill(source: string, paths: string[], cancellation: Cancellation): Promise<SkillData> {
    return new SkillInstaller(new NativeWebTransport()).install(source, paths, cancellation);
  }
  prepareMcp(server: McpServer, request: McpRequest, cancellation: Cancellation, confirm: boolean = true): Promise<McpServer> {
    return prepareNativeMcp(server, request, this.approval, this.context, cancellation, confirm);
  }
  async testMcp(server: McpServer, cancellation: Cancellation): Promise<number> { return (await new McpClient(server).list(cancellation)).length; }
}

// Native composition root. The session service can also run with an in-memory repository/model.
export function createNativeSessionService(filesDir: string, workspaceFilesDir: string, approval: ToolApproval = new ToolApproval(), context?: common.UIAbilityContext, browser?: BrowserSession): SessionService {
  Attachments.configure(workspaceFilesDir);
  UsageLedger.configure(filesDir).catch((error: Error) => { UsageLedger.error = error.message; });
  const providers = new ProviderRegistry(() => huaweiAccount.requireLogin()); const credentials = new CredentialStore();
  const session = new SessionService(new ConversationStore(filesDir), new AgentRuntime(providers, credentials, new NativeUsageRecorder(),
    (content, cancellation) => WebUiPreflight.validate(content, cancellation), new NativeOrchestrationExecutor(), browser), credentials,
    new NativeSessionResources(workspaceFilesDir, providers, approval, context, browser));
  if (context) { backgroundGeneration.attach(session, context); completionNotifications.attach(session, context); }
  if (browser) {
    browser.configure((policy) => session.setBrowserPolicy(policy), (event, fields, error) => Diagnostics.log(error === undefined ? 'info' : 'error', 'browser', event, fields, error));
    session.subscribe((event) => { if (event.data) { browser.updatePolicy(event.data.extensions?.browserPolicy || 'unset'); } });
  }
  return session;
}
