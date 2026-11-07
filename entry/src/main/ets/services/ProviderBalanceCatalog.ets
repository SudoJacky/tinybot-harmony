import { PanelSpec } from '../model/LifePanel';
import { PanelSchema } from '../model/PanelContract';
import { BalancePanelAccount, BalancePanelData, ProviderBalanceSource } from './ProviderBalanceSource';

interface BalanceCatalog { accounts: BalancePanelAccount[]; definition?: PanelSpec; }
export function providerBalanceDefinition(): PanelSpec | undefined {
  const accounts = ProviderBalanceSource.accounts();
  const schema: PanelSchema = { type: 'object', required: ['accounts', 'providerId', 'providerName', 'amounts', 'checkedAt'],
    properties: {
      'accounts': { type: 'array', items: { type: 'object', required: ['id', 'name'], properties: { 'id': { type: 'string' }, 'name': { type: 'string' }, 'presetId': { type: 'string' } } } },
      'providerId': { type: 'string' }, 'providerName': { type: 'string' }, 'checkedAt': { type: 'number' },
      'available': { type: 'boolean' }, 'notice': { type: 'string' },
      'amounts': { type: 'array', items: { type: 'object', required: ['currency', 'label', 'kind'], properties: {
        'currency': { type: 'string' }, 'label': { type: 'string' }, 'kind': { type: 'string' },
        'total': { type: 'string' }, 'used': { type: 'string' }, 'limit': { type: 'string' },
        'granted': { type: 'string' }, 'toppedUp': { type: 'string' }, 'resetAt': { type: 'string' }, 'unlimited': { type: 'boolean' }
      } } }
    } };
  const data: BalancePanelData = { accounts: accounts, providerId: accounts[0]?.id || '', providerName: accounts[0]?.name || '', amounts: [], checkedAt: 0 };
  const definition: PanelSpec | undefined = accounts.length ? { version: 2, title: 'Provider Balance', size: 'M', nodes: [], data: data,
    source: { type: 'provider-balance', providerIds: accounts.map((account) => account.id) }, refreshMinutes: 5,
    inputs: { 'providerId': { type: 'string', default: accounts[0].id, options: accounts.map((account) => account.id) } }, dataSchema: schema,
    checks: [{ action: 'click', selector: '#account' }, { action: 'click', selector: '#account-close' }] } : undefined;
  return definition;
}
export function providerBalanceCatalog(): string {
  const accounts = ProviderBalanceSource.accounts(), definition = providerBalanceDefinition();
  const catalog: BalanceCatalog = { accounts: accounts, definition: definition };
  return JSON.stringify(catalog);
}
