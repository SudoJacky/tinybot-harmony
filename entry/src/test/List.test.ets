import coreTests from './Core.test';
import agentTests from './Agent.test';
import runtimeTests from './Runtime.test';
import providerTests from './Providers.test';
import contextTests from './ContextManagement.test';
import profileTests from './ProviderProfiles.test';
import extensionTests from './Extensions.test';
import pendingInputTests from './PendingInput.test';
import sessionServiceTests from './SessionService.test';

export default function tests(): void {
  coreTests();
  agentTests();
  runtimeTests();
  providerTests();
  contextTests();
  profileTests();
  extensionTests();
  pendingInputTests();
  sessionServiceTests();
}
