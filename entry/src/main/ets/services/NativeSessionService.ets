import { ProviderEffects } from './providers/Provider';
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
import { Attachments } from './Attachments';
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

class NativeSessionResources implements SessionResources {
  private workspaces: WorkspaceStore;
  private providers: ProviderRegistry;
  private approval: ToolApproval;
  private profiles: ProviderProfile[] = [];
  private context?: common.UIAbilityContext;
  constructor(workspaceFilesDir: string, providers: ProviderRegistry, approval: ToolApproval, context?: common.UIAbilityContext) {
    this.context = context;
    this.workspaces = new WorkspaceStore(workspaceFilesDir); this.providers = providers; this.approval = approval;
  }
  createId(): string { return util.generateRandomUUID(); }
  ensureWorkspace(id: string): Promise<void> { return this.workspaces.ensureThread(id); }
  tools(id: string, extensions: ExtensionSettings, selected: string, productivity?: ProductivityData, attachments: Attachment[] = [], live?: LiveResources): AgentTools {
    const groups: AgentTools[] = [new WorkspaceTools(new NativeWorkspaceFiles(this.workspaces.pathFor(id))),
      new SkillTools(extensions.skills, selected, live ? () => live.skills() : undefined), new InteractionTools(this.approval)];
    groups.push(new CodeExecutionTools(new NativeCodeExecutor()));
    if (extensions.webEnabled) { groups.push(new WebTools(new NativeWebTransport())); }
    if (productivity) { groups.push(new McpTools(productivity.servers, this.approval, (server) => new McpClient(server), live ? () => live.servers() : undefined)); }
    const reference = productivity?.options?.image; const profile = this.profiles.find((item) => item.id === reference?.providerId && item.enabled);
    if (reference && profile && profile.models.includes(reference.modelId)) { groups.push(new ImageTools(profile, reference, this.workspaces.pathFor(id), this.approval, attachments)); }
    return new RuleTools(new ToolSet(groups), productivity?.options?.readOnly === true);
  }
  async afterTask(threadId: string, messageId: string, content: string): Promise<void> {
    await new NativeWorkspaceFiles(this.workspaces.pathFor(threadId)).write('任务结果/' + messageId + '.md', content, new Cancellation());
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
export function createNativeSessionService(filesDir: string, workspaceFilesDir: string, approval: ToolApproval = new ToolApproval(), context?: common.UIAbilityContext): SessionService {
  Attachments.configure(workspaceFilesDir);
  UsageLedger.configure(filesDir).catch((error: Error) => { UsageLedger.error = error.message; });
  const providers = new ProviderRegistry(); const credentials = new CredentialStore();
  return new SessionService(new ConversationStore(filesDir), new AgentRuntime(providers, credentials, new NativeUsageRecorder(),
    (content, cancellation) => WebUiPreflight.validate(content, cancellation), new NativeOrchestrationExecutor()), credentials,
    new NativeSessionResources(workspaceFilesDir, providers, approval, context));
}
