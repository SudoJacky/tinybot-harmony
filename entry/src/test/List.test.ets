import coreTests from './Core.test';
import agentTests from './Agent.test';
import runtimeTests from './Runtime.test';
import providerTests from './Providers.test';

export default function tests(): void {
  coreTests();
  agentTests();
  runtimeTests();
  providerTests();
}
