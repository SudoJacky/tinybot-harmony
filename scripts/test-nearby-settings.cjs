const assert = require('node:assert/strict');
const { from } = require('./test-parallel-sessions.cjs');
const { emptyData } = from('model/Conversation');
const { defaultProductivity } = from('model/Productivity');
const { defaultExtensions } = from('model/Skills');
const { mergePeerSettings } = from('model/PeerSettingsMerge');
const { peerSettingsText, parsePeerSettings } = from('model/PeerSyncData');
const copy = value => JSON.parse(JSON.stringify(value));
const snapshot = data => parsePeerSettings(peerSettingsText(data));
const local = emptyData();
local.productivity = defaultProductivity(); local.extensions = defaultExtensions();
local.providerProfiles = [{ id: 'p', name: 'API', presetId: 'custom', protocol: 'chat-completions', baseUrl: 'https://api.example/v1',
  models: ['model'], credentialAlias: 'device-key', enabled: true }];
local.productivity.servers = [{ id: 's', name: 'Tools', url: 'https://tools.example/mcp', credentialAlias: 'mcp-key', enabled: true }];
let previous = snapshot(local), remote = copy(previous);
remote.profiles[0].name = 'Renamed'; remote.profiles[0].models.push('second'); remote.servers[0].name = 'Renamed tools';
mergePeerSettings(local, [{ origin: 'peer', current: remote, previous }]);
assert.equal(local.providerProfiles[0].name, 'Renamed');
assert.equal(local.providerProfiles[0].credentialAlias, 'device-key'); assert.equal(local.providerProfiles[0].enabled, true);
assert.equal(local.productivity.servers[0].credentialAlias, 'mcp-key');
console.log('PASS remote metadata updates preserve device credentials when service origins are unchanged');

previous = copy(remote); remote.profiles[0].baseUrl = 'https://new-api.example/v1'; remote.servers[0].url = 'https://new-tools.example/mcp';
mergePeerSettings(local, [{ origin: 'peer', current: remote, previous }]);
assert.equal(local.providerProfiles[0].credentialAlias, ''); assert.equal(local.providerProfiles[0].pendingSetup, true);
assert.equal(local.providerProfiles[0].enabled, false); assert.equal(local.productivity.servers[0].enabled, false);
assert.equal(local.productivity.servers[0].credentialAlias, '');
console.log('PASS remote endpoint changes disable connections and cannot reuse local secrets');

previous = copy(remote); local.providerProfiles[0].name = 'Local edit'; remote.profiles[0].name = 'Remote edit';
mergePeerSettings(local, [{ origin: 'peer', current: remote, previous }]);
assert.equal(local.providerProfiles[0].name, 'Local edit');
assert.deepEqual(Array.from(local.nearbyConflicts[0].keys), ['profile:p']);
const reloaded = copy(local);
mergePeerSettings(reloaded, [{ origin: 'peer', current: remote, previous: remote }]);
assert.equal(reloaded.nearbyConflicts.length, 1, 'Repeated synchronization must not hide an unresolved conflict');
mergePeerSettings(reloaded, [{ origin: 'peer', current: remote, previous: remote, force: ['profile:p'] }]);
assert.equal(reloaded.providerProfiles[0].name, 'Remote edit'); assert.equal(reloaded.nearbyConflicts, undefined);
console.log('PASS concurrent edits retain both choices across reload and resolve only selected conflicts');

previous = copy(remote); remote.profiles = []; remote.servers = [];
mergePeerSettings(reloaded, [{ origin: 'peer', current: remote, previous }]);
assert.equal(reloaded.providerProfiles.length, 0); assert.equal(reloaded.productivity.servers.length, 0);
mergePeerSettings(local, [{ origin: 'peer', current: remote, previous }]);
assert.equal(local.providerProfiles.length, 1); assert.ok(local.nearbyConflicts[0].keys.includes('profile:p'));
mergePeerSettings(local,[{origin:'peer',current:remote,previous:remote,force:['profile:p']}]);
assert.equal(local.providerProfiles.length,0);assert.equal(local.nearbyConflicts,undefined);
console.log('PASS unchanged records follow remote deletion while concurrent local edits remain recoverable');
