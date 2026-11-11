// Runs inside the native-adapter harness with real files, production import code and real AES-GCM.
module.exports = async function completeBackup({ load, fs, nativePath, secrets, model, crypto, ConversationStore, idleRuntime, Attachments, backupAccount, preferences }) {
  const assert = require('node:assert/strict');
  const { legacyBackupFixture } = require('./backup-fixture.cjs');
  const { createBackupFile, readBackupFile } = load('services/Backup');
  const { SessionService } = load('services/SessionService');
  const { CredentialStore } = load('services/CredentialStore');
  const { MailAccounts } = load('services/MailAccounts');
  const { PanelCredentials } = load('services/PanelCredentials');
  const { parsePanelRecord } = load('model/LifePanel');
  const { defaultAppearance } = load('model/Appearance');
  const { defaultExtensions } = load('model/Skills');
  const { defaultProductivity } = load('model/Productivity');
  const { defaultAssistantOptions } = load('model/AssistantOptions');
  const { seedBuiltinSkills } = load('model/BuiltinSkills');
  const { UsageLedger } = load('services/UsageLedger');
  const configureUsage = async root => {
    await UsageLedger.queue;
    UsageLedger.records = []; UsageLedger.positions = new Map(); UsageLedger.dirty = new Set();
    UsageLedger.path = ''; UsageLedger.ready = false;
    await UsageLedger.configure(root);
  };
  const context = root => { fs.mkdirSync(nativePath(root + '/cache'), { recursive: true }); return { filesDir: root, cacheDir: root + '/cache', getApplicationContext() { return this; } }; };
  const source = context('/sandbox/complete-source'), destination = context('/sandbox/complete-target');
  const write = (root, path, value) => { const target = nativePath(root + '/workspace/' + path); fs.mkdirSync(require('node:path').dirname(target), { recursive: true }); fs.writeFileSync(target, typeof value === 'string' ? value : JSON.stringify(value)); };
  const read = (root, path) => JSON.parse(fs.readFileSync(nativePath(root + '/workspace/' + path), 'utf8'));
  const panelPath = id => 'owner/life-panels/' + id + '/panel.json';
  const panel = (id, source, data = { count: 1 }) => ({ version: 1, id,
    definition: { version: 1, title: id, size: 'M', data, source, nodes: [{ id: 'count', kind: 'Metric', value: { path: '/data/count' } }] },
    data, configRevision: 1, sourcePath: id + '.panel.json', sourceThreadId: 'owner', user: {},
    createdAt: 1, updatedAt: 1, refreshedAt: 1, attemptedAt: 1, error: '', archived: false,
    viewState: { revision: 'view-1', value: { expanded: true } } });
  const profile = { id: 'provider-old', name: 'Model', protocol: 'chat-completions', baseUrl: 'https://model.invalid/v1',
    credentialAlias: 'source-model', enabled: true, noApiKey: false, models: ['model'], contextWindow: 32768 };
  const data = model.emptyData(); data.providerProfiles = [profile];
  data.config = { ...data.config, configured: true, providerId: profile.id, model: 'model', baseUrl: profile.baseUrl,
    credentialAlias: profile.credentialAlias, userDocument: 'Call me Lin', systemPrompt: 'Personal instructions', autoCompact: false, contextWindow: 65536, reasoning: 'high', images: true, requestUsage: true };
  data.threads = [{ id: 'owner', title: 'Board owner', updatedAt: 1, messages: [], draft: 'Unfinished draft',
    pendingInputs: [{ id: 'pending-old', mode: 'followUp', text: 'Keep this unsent instruction' }], queuePaused: false,
    modelRef: { providerId: profile.id, modelId: 'model' } }]; data.activeThreadId = 'owner';
  data.productivity = defaultProductivity();
  data.productivity.options = defaultAssistantOptions();
  data.productivity.templates = [{ id: 'summarize', name: 'Summarize', content: 'Customized factory template {{input}}' }];
  data.productivity.servers = [{ id: 'mcp-old', name: 'Private MCP', url: 'https://mcp.invalid/api', enabled: true, authType: 'bearer', credentialAlias: 'source-mcp' },
    { id: 'mcp-public', name: 'Public MCP', url: 'https://public.invalid/mcp', enabled: true, credentialAlias: '' }];
  Object.assign(data.productivity.options, { miniAppsEnabled: true, autoMemory: false, saveSummary: true, readOnly: true,
    autoRoute: true, fast: { providerId: profile.id, modelId: 'model' },
    title: { providerId: profile.id, modelId: 'model' }, teamWorker: { providerId: profile.id, modelId: 'model' },
    memory: { providerId: profile.id, modelId: 'model' }, capabilities: [{ providerId: profile.id, modelId: 'model', reasoning: 'high', images: true, requestUsage: true, contextWindow: 65536 }],
    search: { provider: 'tavily', enabled: true, baseUrl: 'https://api.tavily.com', credentialAlias: 'source-search', tavily: { baseUrl: 'https://api.tavily.com', credentialAlias: 'source-search' } } });
  data.extensions = defaultExtensions(); seedBuiltinSkills(data.extensions);
  data.extensions.webEnabled = false; data.extensions.browserPolicy = 'disabled';
  data.extensions.skills[0].document += '\nUser changes'; data.extensions.skills[0].enabled = false;
  const rawSecrets = ['MODEL_PRIVATE_COMPLETE', 'MCP_PRIVATE_COMPLETE', 'SEARCH_PRIVATE_COMPLETE', 'MAIL_PRIVATE_COMPLETE', 'PANEL_PRIVATE_COMPLETE'];
  secrets.clear(); ['source-model', 'source-mcp', 'source-search'].forEach((key, index) => secrets.set(key, rawSecrets[index]));
  const feedbackIdentity = 'fi_' + 'x'.repeat(43); secrets.set('tinybot.feedback.identity.v1', feedbackIdentity);
  const mail = { id: 'mail-old', name: 'Inbox', host: 'imap.mail.invalid', port: 993, username: 'lin@mail.invalid', enabled: true, allowBody: true };
  await new MailAccounts().save(mail, rawSecrets[3]);
  const apiSource = { type: 'api', url: 'https://metrics.invalid/data', auth: { type: 'bearer' } };
  const oauthSource = { type: 'api', url: 'https://oauth-metrics.invalid/data', auth: { type: 'oauth', oauth: {
    clientId: 'panel-client', authorizationEndpoint: 'https://oauth.invalid/auth', tokenEndpoint: 'https://oauth.invalid/token' } } };
  const oauthSecret = JSON.stringify({ resource: oauthSource.url, tokenEndpoint: oauthSource.auth.oauth.tokenEndpoint, clientId: 'panel-client', accessToken: 'OAUTH_PRIVATE_COMPLETE', refreshToken: 'REFRESH_PRIVATE_COMPLETE', expiresAt: Date.now() + 3600000 });
  await new PanelCredentials(source.filesDir + '/workspace/owner').save('api', apiSource, rawSecrets[4]);
  await new PanelCredentials(source.filesDir + '/workspace/owner').restore('oauth', oauthSource, { oauth: oauthSecret });
  write(source.filesDir, panelPath('api'), panel('api', apiSource));
  write(source.filesDir, panelPath('oauth'), panel('oauth', oauthSource));
  const walletPanel = panel('wallet', { type: 'provider-balance', providerIds: [profile.id] }, { count: 1, providerId: profile.id, accounts: [{ id: profile.id }] });
  walletPanel.definition.inputs = { providerId: { type: 'string', default: profile.id, options: [profile.id] } };
  walletPanel.inputs = { providerId: profile.id };
  write(source.filesDir, panelPath('wallet'), walletPanel);
  write(source.filesDir, panelPath('mail'), panel('mail', { type: 'mail', mail: { accountId: mail.id, folder: 'INBOX' } }));
  for (const id of ['api', 'oauth', 'wallet', 'mail']) parsePanelRecord(JSON.stringify(read(source.filesDir, panelPath(id))), id);
  write(source.filesDir, 'orphan/note.txt', 'Keep orphan workspace');
  // The retired runtime must not parse or rewrite historical app bytes, even malformed manifests.
  const retiredFiles = {
    'owner/mini-apps/ledger/app.json': '{"version":1,"retired":true}',
    'owner/mini-apps/ledger/data.json': '{"revision":"old","value":{"count":12}}',
    'retired-owner/mini-apps/legacy/app.json': 'unparseable legacy manifest\n',
    'retired-owner/mini-apps/legacy/data.json': '{"value":{"entries":[1,2,3]}}',
    'retired-owner/mini-apps/legacy/data-v2.json': '{"value":{"entries":[4,5]}}'
  };
  for (const [path, bytes] of Object.entries(retiredFiles)) write(source.filesDir, path, bytes);
  const board = { version: 2, id: 'dashboard', title: 'Dashboard', description: '', archived: false, createdAt: 1, updatedAt: 1,
    items: [{ workspaceId: 'owner', panelId: 'api', mountId: 'mounted-api', x: 0, y: 0, w: 6, h: 8, viewState: { revision: 'mount-1', value: { expanded: false } } }] };
  write(source.filesDir, 'boards/life-boards/dashboard/board.json', board);
  await configureUsage(source.filesDir);
  UsageLedger.record({ id: 'request-old', provider: 'Provider', model: 'model', startedAt: 1, durationMs: 10, status: 'complete', tokens: { input: 100, output: 200 } });
  const settings = preferences.getPreferencesSync(source, { name: 'tinybot-ui' });
  settings.putSync('appearance', JSON.stringify({ ...defaultAppearance(), accent: 'blue' })); settings.putSync('language', 'en');
  settings.putSync('autoCloudBackupEnabled', false); settings.putSync('reviewInvitation', JSON.stringify({ completedTasks: 4, lastAskedAt: 1, stopped: true }));
  settings.putSync('seenAnnouncementIds', ['notice-old']);
  preferences.getPreferencesSync(source, { name: 'tinybot-feedback' }).putSync('seenReplies', JSON.stringify({ replyOld: '2026-11-07T00:00:00Z' }));
  settings.putSync('privacyConsent', true); settings.putSync('huaweiAccountToken', 'NEVER_MIGRATE');
  Attachments.configure(source.filesDir);
  const original = JSON.stringify(data), archive = await createBackupFile(source, data), bytes = fs.readFileSync(nativePath(archive));
  assert.equal(JSON.stringify(data), original, 'Export never mutates live settings');
  const envelope = legacyBackupFixture(bytes), publicText = JSON.stringify(envelope);
  for (const key of [...rawSecrets, feedbackIdentity, 'OAUTH_PRIVATE_COMPLETE', 'REFRESH_PRIVATE_COMPLETE', 'NEVER_MIGRATE']) assert.ok(!publicText.includes(key), 'No credential or system authorization in public backup metadata');
  assert.equal(envelope.data.config.systemPrompt, data.config.systemPrompt);
  assert.deepEqual(envelope.data.productivity.templates, [], 'New archives exclude legacy prompt templates');
  assert.equal(envelope.data.productivity.options.search.enabled, false, 'Public Tavily metadata has no live alias');
  secrets.clear(); await configureUsage(destination.filesDir); Attachments.configure(destination.filesDir);
  assert.equal(UsageLedger.list().length, 0, 'Destination starts with a cold empty ledger');
  backupAccount.openID = 'wrong-account';
  await assert.rejects(readBackupFile(destination, archive, model.emptyData()));
  assert.equal(fs.existsSync(nativePath(destination.filesDir + '/workspace')), false, 'Wrong account writes no workspaces');
  backupAccount.openID = 'fixture-openid-A';
  const redirected = structuredClone(envelope); redirected.data.productivity.options.search.baseUrl = 'https://redirect.invalid';
  const redirectedPath = source.cacheDir + '/redirected.json'; fs.writeFileSync(nativePath(redirectedPath), JSON.stringify(redirected));
  await assert.rejects(readBackupFile(destination, redirectedPath, model.emptyData()), /配置不一致/);
  assert.equal(fs.existsSync(nativePath(destination.filesDir + '/workspace')), false, 'Redirected credential scope is rejected before extracting workspaces');
  const vault = new CredentialStore();
  const resources = { createId: () => crypto.randomUUID(), ensureWorkspace: async () => {}, configureProviders() {}, reportError() {},
    tools: () => ({ definitions: () => [], execute: async () => { throw Error('No tools run during restore'); } }) };
  const repository = new ConversationStore(destination.filesDir);
  const session = new SessionService(repository, idleRuntime(vault), vault, resources); await session.initialize();
  const restored = await readBackupFile(destination, archive, session.snapshot());
  assert.equal(await session.importSnapshot(restored), true, session.state.error);
  const result = session.snapshot();
  assert.equal(result.threads.find(item => item.id === 'owner').draft, 'Unfinished draft');
  assert.equal(result.threads.find(item => item.id === 'owner').pendingInputs[0].text, 'Keep this unsent instruction');
  assert.equal(result.threads.find(item => item.id === 'owner').queuePaused, true, 'Restored pending instructions remain paused');
  assert.equal(await vault.read(result.config.credentialAlias), rawSecrets[0]); assert.equal(result.config.configured, true);
  assert.equal(result.config.userDocument, 'Call me Lin'); assert.equal(result.config.contextWindow, 65536);
  assert.equal(result.productivity.options.memory.providerId, profile.id);
  assert.equal(result.productivity.options.miniAppsEnabled, undefined, 'Import does not restore the retired feature toggle');
  for (const [path, bytes] of Object.entries(retiredFiles)) {
    assert.equal(fs.readFileSync(nativePath(destination.filesDir + '/workspace/' + path), 'utf8'), bytes, 'Retired app files survive backup and restore byte for byte');
  }
  assert.equal(result.productivity.options.title.providerId, profile.id);
  assert.equal(result.productivity.options.teamWorker.providerId, profile.id);
  assert.equal(result.productivity.options.autoRoute, undefined, 'Import does not restore retired automatic routing');
  assert.equal(result.productivity.templates.length, 0);
  assert.equal(result.extensions.skills[0].document, data.extensions.skills[0].document); assert.equal(result.extensions.skills[0].enabled, false);
  assert.equal(result.extensions.webEnabled, false); assert.equal(result.extensions.browserPolicy, 'disabled');
  assert.equal(await vault.read(result.productivity.servers[0].credentialAlias), rawSecrets[1]); assert.equal(result.productivity.servers[0].enabled, true);
  assert.equal(result.productivity.servers[1].enabled, true, 'Anonymous MCP remains enabled');
  assert.equal(result.productivity.options.search.enabled, true); assert.equal(await vault.read(result.productivity.options.search.credentialAlias), rawSecrets[2]);
  assert.equal((await new MailAccounts().connection(mail.id)).secret, rawSecrets[3]);
  assert.equal(await new PanelCredentials(destination.filesDir + '/workspace/owner').secret('api', apiSource), rawSecrets[4]);
  assert.equal(await new PanelCredentials(destination.filesDir + '/workspace/owner').secret('oauth', oauthSource), 'OAUTH_PRIVATE_COMPLETE');
  assert.equal(await vault.read('tinybot.feedback.identity.v1'), feedbackIdentity);
  assert.deepEqual(read(destination.filesDir, 'boards/life-boards/dashboard/board.json'), board);
  assert.equal(fs.readFileSync(nativePath(destination.filesDir + '/workspace/orphan/note.txt'), 'utf8'), 'Keep orphan workspace');
  const restoredSettings = preferences.getPreferencesSync(destination, { name: 'tinybot-ui' });
  assert.equal(restoredSettings.getSync('language', ''), 'en'); assert.equal(JSON.parse(restoredSettings.getSync('appearance', '')).accent, 'blue');
  assert.deepEqual(Array.from(restoredSettings.getSync('seenAnnouncementIds', [])), ['notice-old']);
  assert.equal(JSON.parse(preferences.getPreferencesSync(destination, { name: 'tinybot-feedback' }).getSync('seenReplies', '{}')).replyOld, '2026-11-07T00:00:00Z');
  assert.equal(restoredSettings.getSync('privacyConsent', 'missing'), 'missing'); assert.equal(restoredSettings.getSync('huaweiAccountToken', 'missing'), 'missing');
  assert.ok(UsageLedger.list().some(item => item.id === 'request-old'));
  // Existing local changes and keys win; missing files within the same workspace are filled.
  const localPanel = read(destination.filesDir, panelPath('api')); localPanel.data.count = 9; write(destination.filesDir, panelPath('api'), localPanel);
  fs.unlinkSync(nativePath(destination.filesDir + '/workspace/owner/life-panels/mail/panel.json'));
  restoredSettings.putSync('language', 'zh-CN');
  await vault.update(result.config.credentialAlias, 'LOCAL_MODEL_PRIVATE');
  await new PanelCredentials(destination.filesDir + '/workspace/owner').save('api', apiSource, 'LOCAL_PANEL_PRIVATE');
  UsageLedger.record({ id: 'request-old', provider: 'Provider', model: 'model', startedAt: 1, durationMs: 999, status: 'complete' });
  const before = JSON.stringify(session.snapshot()), beforeAliases = [...secrets.keys()].sort();
  assert.equal(await session.importSnapshot(await readBackupFile(destination, archive, session.snapshot())), true, session.state.error);
  assert.equal(JSON.stringify(session.snapshot()), before, 'Repeated restore does not duplicate records or mutate model choices');
  assert.deepEqual([...secrets.keys()].sort(), beforeAliases, 'Repeated restore does not mint credentials');
  assert.equal(read(destination.filesDir, panelPath('api')).data.count, 9);
  assert.equal(read(destination.filesDir, panelPath('mail')).id, 'mail');
  assert.equal(await vault.read(result.config.credentialAlias), 'LOCAL_MODEL_PRIVATE');
  assert.equal(await new PanelCredentials(destination.filesDir + '/workspace/owner').secret('api', apiSource), 'LOCAL_PANEL_PRIVATE');
  assert.equal(restoredSettings.getSync('language', ''), 'zh-CN');
  assert.equal(UsageLedger.list().find(item => item.id === 'request-old').durationMs, 999);
  // Existing endpoints under different IDs must bind imported cards to local services and mailboxes.
  const mergeTarget = context('/sandbox/complete-merge'); secrets.clear();
  const local = model.emptyData(); local.providerProfiles = [{ ...profile, id: 'provider-local', credentialAlias: 'local-key' }]; secrets.set('local-key', 'LOCAL_KEEP');
  local.productivity = defaultProductivity(); local.productivity.servers = [{ ...data.productivity.servers[0], id: 'mcp-local', credentialAlias: 'local-mcp' }]; secrets.set('local-mcp', 'LOCAL_MCP_KEEP');
  await new MailAccounts().save({ ...mail, id: 'mail-local' }, 'LOCAL_MAIL_KEEP');
  const mergeRepo = new ConversationStore(mergeTarget.filesDir); await mergeRepo.save(local);
  const mergeSession = new SessionService(mergeRepo, idleRuntime(vault), vault, resources); await mergeSession.initialize();
  await configureUsage(mergeTarget.filesDir); Attachments.configure(mergeTarget.filesDir);
  assert.equal(await mergeSession.importSnapshot(await readBackupFile(mergeTarget, archive, mergeSession.snapshot())), true, mergeSession.state.error);
  const wallet = read(mergeTarget.filesDir, panelPath('wallet'));
  assert.deepEqual(wallet.definition.source.providerIds, ['provider-local']); assert.equal(wallet.data.providerId, 'provider-local'); assert.equal(wallet.data.accounts[0].id, 'provider-local');
  assert.equal(read(mergeTarget.filesDir, panelPath('mail')).definition.source.mail.accountId, 'mail-local');
  assert.equal(mergeSession.snapshot().productivity.options.memory.providerId, 'provider-local');
  assert.equal(mergeSession.snapshot().productivity.options.title.providerId, 'provider-local');
  assert.equal(mergeSession.snapshot().productivity.options.teamWorker.providerId, 'provider-local');
  assert.equal(await vault.read('local-key'), 'LOCAL_KEEP'); assert.equal(await vault.read('local-mcp'), 'LOCAL_MCP_KEEP');
  assert.equal((await new MailAccounts().connection('mail-local')).secret, 'LOCAL_MAIL_KEEP');
  // Settings commit failure rolls back every new secret and supports a fresh retry.
  const failingTarget = context('/sandbox/complete-failure'); secrets.clear();
  const failRepo = new ConversationStore(failingTarget.filesDir), failSession = new SessionService(failRepo, idleRuntime(vault), vault, resources); await failSession.initialize();
  await configureUsage(failingTarget.filesDir); Attachments.configure(failingTarget.filesDir);
  const pending = await readBackupFile(failingTarget, archive, failSession.snapshot());
  const save = failRepo.save.bind(failRepo); failRepo.save = async () => { throw Error('Injected settings commit failure'); };
  assert.equal(await failSession.importSnapshot(pending), false); assert.match(failSession.state.error, /Injected settings commit failure/);
  assert.equal(secrets.size, 0, 'Every newly created credential and mailbox index is rolled back');
  failRepo.save = save;
  assert.equal(await failSession.importSnapshot(await readBackupFile(failingTarget, archive, failSession.snapshot())), true, failSession.state.error);
  assert.equal(await new PanelCredentials(failingTarget.filesDir + '/workspace/owner').secret('api', apiSource), rawSecrets[4], 'Retry restores card authentication too');
  const partialTarget = context('/sandbox/complete-partial'); secrets.clear();
  const partialRepo = new ConversationStore(partialTarget.filesDir), partialSession = new SessionService(partialRepo, idleRuntime(vault), vault, resources);
  await partialSession.initialize(); await configureUsage(partialTarget.filesDir); Attachments.configure(partialTarget.filesDir);
  const restoreUsage = UsageLedger.restoreBackup;
  try {
    UsageLedger.restoreBackup = async () => { throw Error('Injected usage restore failure'); };
    assert.equal(await partialSession.importSnapshot(await readBackupFile(partialTarget, archive, partialSession.snapshot())), false);
    assert.match(partialSession.state.error, /主要数据已导入.*Injected usage restore failure/);
    assert.equal(partialSession.snapshot().config.configured, true, 'Committed settings remain usable after an additional-data failure');
    assert.equal(await vault.read(partialSession.snapshot().config.credentialAlias), rawSecrets[0]);
  } finally { UsageLedger.restoreBackup = restoreUsage; }
  const aliasesBeforeRetry = [...secrets.keys()].sort();
  assert.equal(await partialSession.importSnapshot(await readBackupFile(partialTarget, archive, partialSession.snapshot())), true, partialSession.state.error);
  assert.deepEqual([...secrets.keys()].sort(), aliasesBeforeRetry);
  assert.equal(UsageLedger.list().filter(item => item.id === 'request-old').length, 1);
  assert.equal(preferences.getPreferencesSync(partialTarget, { name: 'tinybot-ui' }).getSync('language', ''), 'en');
  const capacityTarget = context('/sandbox/complete-capacity'); secrets.clear();
  const capacityData = model.emptyData(); capacityData.productivity = defaultProductivity();
  capacityData.productivity.servers = Array.from({ length: 10 }, (_, index) => ({ id: 'local-' + index, name: 'Local ' + index,
    url: 'https://local' + index + '.invalid/mcp', enabled: true, credentialAlias: '' }));
  const capacityRepo = new ConversationStore(capacityTarget.filesDir); await capacityRepo.save(capacityData);
  const capacitySession = new SessionService(capacityRepo, idleRuntime(vault), vault, resources); await capacitySession.initialize();
  Attachments.configure(capacityTarget.filesDir);
  const capacityBefore = JSON.stringify(capacitySession.snapshot());
  assert.equal(await capacitySession.importSnapshot(await readBackupFile(capacityTarget, archive, capacitySession.snapshot())), false, 'A merge above the service limit must fail explicitly');
  assert.equal(JSON.stringify(capacitySession.snapshot()), capacityBefore);
  assert.equal(secrets.size, 0);
  assert.equal(fs.existsSync(nativePath(capacityTarget.filesDir + '/workspace/' + panelPath('api'))), false, 'Admission failure discards newly prepared files too');
};
