import { ProductivityData, Attachment } from '../model/Productivity';
import { ImageTools } from './ImageTools';
import { InteractionTools } from './InteractionTools';
import { UsageLedger } from './UsageLedger';
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

class NativeSessionResources implements SessionResources {
  private workspaces: WorkspaceStore;
  private providers: ProviderRegistry;
  private approval: ToolApproval;
  private profiles: ProviderProfile[] = [];
  constructor(workspaceFilesDir: string, providers: ProviderRegistry, approval: ToolApproval) {
    this.workspaces = new WorkspaceStore(workspaceFilesDir); this.providers = providers; this.approval = approval;
  }
  createId(): string { return util.generateRandomUUID(); }
  ensureWorkspace(id: string): Promise<void> { return this.workspaces.ensureThread(id); }
  tools(id: string, extensions: ExtensionSettings, selected: string, productivity?: ProductivityData, attachments: Attachment[] = []): AgentTools {
    const groups: AgentTools[] = [new WorkspaceTools(new NativeWorkspaceFiles(this.workspaces.pathFor(id))), new SkillTools(extensions.skills, selected), new InteractionTools(this.approval)];
    if (extensions.webEnabled) { groups.push(new WebTools(new NativeWebTransport())); }
    if (productivity) { groups.push(new McpTools(productivity.servers, this.approval)); }
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
    for (const profile of profiles) { this.providers.register(profileProvider(profile)); }
  }
  reportError(message: string): void { hilog.error(0x0000, 'TinybotSession', '%{public}s', message); }
}

// Native composition root. The session service can also run with an in-memory repository/model.
export function createNativeSessionService(filesDir: string, workspaceFilesDir: string, approval: ToolApproval = new ToolApproval()): SessionService {
  Attachments.configure(workspaceFilesDir);
  UsageLedger.configure(filesDir).catch((error: Error) => { UsageLedger.error = error.message; });
  const providers = new ProviderRegistry(); const credentials = new CredentialStore();
  return new SessionService(new ConversationStore(filesDir), new AgentRuntime(providers, credentials), credentials,
    new NativeSessionResources(workspaceFilesDir, providers, approval));
}
