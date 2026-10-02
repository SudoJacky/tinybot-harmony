import teamTests from './Team.test';
import systemPromptTests from './SystemPrompt.test';
import i18nTests from './I18n.test';
import chatTeamTests from './ChatTeam.test';
import coreTests from './Core.test';
import advancedTests from './Advanced.test';
import productivityTests from './Productivity.test';
import agentTests from './Agent.test';
import runtimeTests from './Runtime.test';
import providerTests from './Providers.test';
import contextTests from './ContextManagement.test';
import profileTests from './ProviderProfiles.test';
import extensionTests from './Extensions.test';
import pendingInputTests from './PendingInput.test';
import sessionServiceTests from './SessionService.test';
import processPresentationTests from './ProcessPresentation.test';

export default function tests(): void {
  processPresentationTests();
  systemPromptTests();
  i18nTests();
  teamTests();
  chatTeamTests();
  advancedTests();
  productivityTests();
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
