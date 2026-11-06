import { PanelSpec } from '../model/LifePanel';
import { PanelSchema } from '../model/PanelContract';
import { BALANCE_PANEL_HTML } from '../model/BalancePanelTemplate';
import { BalancePanelAccount, BalancePanelData, ProviderBalanceSource } from './ProviderBalanceSource';

interface BalanceCatalog { guidance: string; accounts: BalancePanelAccount[]; html: string; definition?: PanelSpec; }
export function providerBalanceCatalog(): string {
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
    checks: [{ action: 'click', selector: '#account' }, { action: 'click', selector: '#account-close' },
      { action: 'click', selector: '#privacy' }] } : undefined;
  const catalog: BalanceCatalog = { accounts: accounts, definition: definition, html: BALANCE_PANEL_HTML,
    guidance: 'Create a v2 HTML Life Panel using the supplied definition and self-contained HTML reference, adapted to the user request. ' +
      'Write an .html and .panel.json, then validate_life_panel and publish_life_panel. Read-only provider-balance is a native data source, not an agent source. ' +
      'Only enabled providers with a supported/configured balance adapter are listed. Empty accounts means setup is required in Settings > provider > balance query settings; never invent a balance. ' +
      'source accepts only type and providerIds. Use inputs.providerId with default/options from that allowlist. ' +
      'Switch via tinybot.panel.refresh({providerId:id}); manual refresh via tinybot.panel.refresh(). Never query during page startup. ' +
      'During manual or background queries, replace the amount with a subtle pulsing skeleton in the same space. Fade the skeleton out and stagger the result digits in when finished, including unchanged balances. Do not show visible loading text; use aria-busy and an accessible label. Keep failures visible and respect balance privacy when restoring the amount. ' +
      'Never request/copy model keys or balance tokens into HTML, chat, definitions or API connections. The host resolves saved credentials and deduplicates queries with Settings. ' +
      'data.amounts[].total is REMAINING, used is spent, limit is total allowance; preserve decimal strings and separate currency/kind/label. Unlimited is not zero. ' +
      'Do not add account balances, key limits or subscription allowances together. ' +
      'A failed refresh retains the last snapshot: use context.status to label it stale, and never show data from a different data.providerId than context.inputs.providerId. ' +
      'Follow the minimal Wallet Card reference: 32px rounded surface, 16px gap above the balance, compact header, centered tabular amount without currency symbols or units, balance privacy and a top-right refresh icon. Omit change indicators, account search, balance/category dropdowns, detail expansion and bottom action buttons. Show the first account balance, or the first returned quota when no account balance is provided. ' +
      'Use accounts[].presetId to select the bundled provider logo on a pale circular background in both the header and account list. Unknown/custom presets use the generic service icon; never infer a brand from account names or API protocol. Keep logo assets inline and offline. ' +
      'The account button expands into an account panel anchored to its origin; rows enter with a short stagger. Amount digits exit upward and enter from below with staggered opacity/transform transitions under 300ms. ' +
      'Keep transitions interruptible, restore focus on picker dismissal, and disable motion for keyboard interaction and prefers-reduced-motion. Keep HTML sandboxed, themed and responsive at half width. ' +
      'Privacy immediately removes all monetary text, including outgoing animated digits and notices. Persist it through tinybot.storage only on user interaction. ' +
      'The supplied checks exercise account panel opening/closing and privacy; source queries are verified separately. Add meaningful checks for any new behavior. Do not add fake Send/Swap/Buy actions.' };
  return JSON.stringify(catalog);
}
