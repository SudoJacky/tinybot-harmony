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
  constructor(workspaceFilesDir: string, providers: ProviderRegistry) {
    this.workspaces = new WorkspaceStore(workspaceFilesDir); this.providers = providers;
  }
  createId(): string { return util.generateRandomUUID(); }
  ensureWorkspace(id: string): Promise<void> { return this.workspaces.ensureThread(id); }
  tools(id: string, extensions: ExtensionSettings, selected: string): AgentTools {
    const groups: AgentTools[] = [new WorkspaceTools(new NativeWorkspaceFiles(this.workspaces.pathFor(id))), new SkillTools(extensions.skills, selected)];
    if (extensions.webEnabled) { groups.push(new WebTools(new NativeWebTransport())); }
    return new ToolSet(groups);
  }
  configureProviders(profiles: ProviderProfile[]): void {
    for (const info of this.providers.list()) { this.providers.unregister(info.id); }
    for (const profile of profiles) { this.providers.register(profileProvider(profile)); }
  }
  reportError(message: string): void { hilog.error(0x0000, 'TinybotSession', '%{public}s', message); }
}

// Native composition root. The session service can also run with an in-memory repository/model.
export function createNativeSessionService(filesDir: string, workspaceFilesDir: string): SessionService {
  const providers = new ProviderRegistry(); const credentials = new CredentialStore();
  return new SessionService(new ConversationStore(filesDir), new AgentRuntime(providers, credentials), credentials,
    new NativeSessionResources(workspaceFilesDir, providers));
}
