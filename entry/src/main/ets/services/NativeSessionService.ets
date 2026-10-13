import { ProviderEffects } from './providers/Provider';
import { PresentTools } from './PresentTools';
import { PreviewTools } from './PreviewTools';
import { PreviewCapture } from './PreviewCapture';
import { savePreviewRepair } from './PreviewRecovery';
import { WebSearchTools } from './WebSearchTools';
import { NativeSearchTransport } from './NativeSearchTransport';
import { ProductivityData, Attachment, McpServer } from '../model/Productivity';
import { LiveResources, McpRequest } from '../model/ResourceManagement';
import { SkillData } from '../model/Skills';
import { common } from '@kit.AbilityKit';
import { prepareNativeMcp } from './NativeResourceSetup';
import { McpClient } from './McpClient';
import { SkillInstaller } from './SkillInstaller';
import { ImageTools } from './ImageTools';
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
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConversationStore } from '../model/ConversationStore';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ExtensionSettings } from '../model/Skills';
import { AgentRuntime } from './AgentRuntime';
import { AgentTools } from './AgentLoop';
import { CredentialStore } from './CredentialStore';
import { SessionResources } from './SessionContracts';
import { SessionService } from './SessionService';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { WorkspaceTools } from './WorkspaceTools';
import { NativeWebTransport } from './NativeWebTransport';
import { WebTools } from './WebTools';
import { SkillTools } from './SkillTools';
import { ToolSet } from './ToolSet';
import { profileProvider } from './providers/DefaultProviders';
import { ProviderRegistry } from './providers/ProviderRegistry';

class NativeProviderEffects implements ProviderEffects {
  hydrate(messages: ModelMessage[]): Promise<ModelMessage[]> { return Attachments.hydrate(messages); }
  recordUsage(record: RequestUsage): void { UsageLedger.record(record); }
}

class NativeUsageRecorder implements UsageRecorder {
  recordTool(id: string, activity: UsageToolActivity): void { UsageLedger.recordTool(id, activity); }
  recordContext(id: string, diagnostics: ContextDiagnostics): void {
    hilog.info(0x0000, 'TinybotContext', 'session=%{public}s %{public}s', id, JSON.stringify(diagnostics));
  }
}

export class NativeSessionResources implements SessionResources {
  private workspaces: WorkspaceStore;
  private providers: ProviderRegistry;
  private approval: ToolApproval;
  private browser?: BrowserSession;
  private profiles: ProviderProfile[] = [];
  private context?: common.UIAbilityContext;
  constructor(workspaceFilesDir: string, providers: ProviderRegistry, approval: ToolApproval, context?: common.UIAbilityContext, browser?: BrowserSession) {
    this.browser = browser;
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
  tools(id: string, extensions: ExtensionSettings, selected: string, productivity?: ProductivityData, attachments: Attachment[] = [], live?: LiveResources, workspaceId?: string): AgentTools {
    const root = this.workspaces.pathFor(workspaceId || id);
    const groups: AgentTools[] = [new WorkspaceTools(new NativeWorkspaceFiles(root)), new AttachmentTools(attachments),
      new SkillTools(extensions.skills, selected, live ? () => live.skills() : undefined), new InteractionTools(this.approval)];
    groups.push(new CodeExecutionTools(new NativeCodeExecutor()));
    groups.push(new PresentTools((path: string) => new NativeWorkspaceFiles(root).checkedPath(path)));
    groups.push(new PreviewTools(new NativeWorkspaceFiles(root), (content, cancellation) => WebUiPreflight.validate(content, cancellation),
      (content, cancellation) => PreviewCapture.capture(content, cancellation)));
    if (extensions.webEnabled) { groups.push(new WebTools(new NativeWebTransport())); }
    if (this.browser) { groups.push(new BrowserTools(this.browser, id, productivity?.options?.readOnly === true)); }
    const search = productivity?.options?.search;
    if (extensions.webEnabled && search?.enabled) {
      groups.push(new WebSearchTools(new NativeSearchTransport(search, new CredentialStore(), id, (record) => UsageLedger.record(record), () => this.profiles)));
    }
    if (productivity) { groups.push(new McpTools(productivity.servers, this.approval, (server) => new McpClient(server), live ? () => live.servers() : undefined)); }
    const reference = productivity?.options?.image; const profile = this.profiles.find((item) => item.id === reference?.providerId && item.enabled);
    if (reference && profile && profile.models.includes(reference.modelId)) { groups.push(new ImageTools(profile, reference, root, this.approval, attachments)); }
    return new RuleTools(new ToolSet(groups), productivity?.options?.readOnly === true);
  }
  async afterTask(threadId: string, messageId: string, content: string, workspaceId?: string): Promise<void> {
    await new NativeWorkspaceFiles(this.workspaces.pathFor(workspaceId || threadId)).write('任务结果/' + messageId + '.md', content, new Cancellation());
  }
  configureProviders(profiles: ProviderProfile[]): void {
    this.profiles = JSON.parse(JSON.stringify(profiles)) as ProviderProfile[];
    for (const info of this.providers.list()) { this.providers.unregister(info.id); }
    for (const profile of profiles) { this.providers.register(profileProvider(profile, new NativeProviderEffects())); }
  }
  reportError(message: string): void { hilog.error(0x0000, 'TinybotSession', '%{public}s', message); }
  reportMemory(message: string): void { hilog.info(0x0000, 'TinybotMemory', '%{public}s', message); }
  reportResources(message: string): void { hilog.info(0x0000, 'TinybotResources', '%{public}s', message); }
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
  const providers = new ProviderRegistry(); const credentials = new CredentialStore();
  const session = new SessionService(new ConversationStore(filesDir), new AgentRuntime(providers, credentials, new NativeUsageRecorder(),
    (content, cancellation) => WebUiPreflight.validate(content, cancellation), new NativeOrchestrationExecutor(), browser), credentials,
    new NativeSessionResources(workspaceFilesDir, providers, approval, context, browser));
  if (browser) {
    browser.configure((policy) => session.setBrowserPolicy(policy), (message) => hilog.info(0x0000, 'TinybotBrowser', '%{public}s', message));
    session.subscribe((event) => { if (event.data) { browser.updatePolicy(event.data.extensions?.browserPolicy || 'unset'); } });
  }
  return session;
}
