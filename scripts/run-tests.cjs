// Every standalone test must declare its prerequisites. Tests run serially to limit HDD contention.
const fs = require('node:fs'), path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const suites = {
  source: [
    'test-answer-speech-native.cjs',
    'test-api20-compat.cjs',
    'test-app-information.cjs',
    'test-appearance.cjs',
    'test-bing-search.cjs',
    'test-browser-annotation.cjs',
    'test-browser.cjs',
    'test-chat-disclosures.cjs',
    'test-code-highlight.cjs',
    'test-code-sandbox.cjs',
    'test-context-alignment.cjs',
    'test-conversation-export.cjs',
    'test-custom-tools.cjs',
    'test-feedback.cjs',
    'test-gemini.cjs',
    'test-harness-features.cjs',
    'test-hosted-privacy.cjs',
    'test-huawei-account.cjs',
    'test-interactive-ui.cjs',
    'test-liquid-toggle.cjs',
    'test-memory.cjs',
    'test-model-dependencies.cjs',
    'test-orchestration.cjs',
    'test-prefix-cache.cjs',
    'test-preview-publication.cjs',
    'test-preview-browser.cjs',
    'test-preview-screenshot.cjs',
    'test-productivity-native.cjs',
    'test-request-context.cjs',
    'test-resources.cjs',
    'test-speech-native.cjs',
    'test-storage-usage.cjs',
    'test-stream-reveal.cjs',
    'test-system-bars-native.cjs',
    'test-team-toggle.cjs',
    'test-tool-catalog.cjs',
    'test-tool-details.cjs',
    'test-tool-schemas.cjs',
    'test-unified-logging.cjs',
    'test-usage-performance.cjs',
    'test-web-ui-preflight.cjs',
    'test-window-viewport.cjs',
  ],
  debug: [
    'test-announcements.cjs',
    'test-browser-panel.cjs',
    'test-context-usage.cjs',
    'test-conversation-share.cjs',
    'test-custom-tools-renderer.cjs',
    'test-developer-diagnostics.cjs',
    'test-drawing-board.cjs',
    'test-help-demo.cjs',
    'test-history-drawer.cjs',
    'test-i18n-native.cjs',
    'test-interactive-ui-renderer.cjs',
    'test-launch-actions-renderer.cjs',
    'test-legal-documents.cjs',
    'test-markdown-performance.cjs',
    'test-message-actions-renderer.cjs',
    'test-message-images-renderer.cjs',
    'test-onboarding.cjs',
    'test-page-transitions.cjs',
    'test-plan-progress.cjs',
    'test-preview-lifecycle.cjs',
    'test-preview-surface.cjs',
    'test-preview-references.cjs',
    'test-project-tree.cjs',
    'test-send-motion.cjs',
    'test-settings-navigation.cjs',
    'test-settings-performance.cjs',
    'test-skill-completion.cjs',
    'test-speech-orb.cjs',
    'test-tablet-workbench.cjs',
    'test-team-renderer.cjs',
    'test-thinking-motion.cjs',
    'test-thread-list-renderer.cjs',
    'test-turn-workflow.cjs',
    'test-usage-filter-sheet.cjs',
    'test-voice-composer.cjs',
    'test-workspace-backup-ui.cjs',
  ],
  release: [
    'test-release-models.cjs',
  ],
  browser: [
    'test-bing-search-dom.cjs',
    'test-browser-dom.cjs',
    'test-web-ui-browser.cjs',
  ],
};

function selectedTests(suite) {
  if (!Object.hasOwn(suites, suite)) throw Error('Unknown test suite: ' + suite);
  const registered = Object.values(suites).flat();
  if (new Set(registered).size !== registered.length) throw Error('A test is registered more than once');
  const present = fs.readdirSync(__dirname).filter(name => /^test-.*\.cjs$/.test(name));
  const missing = present.filter(name => !registered.includes(name));
  const stale = registered.filter(name => !present.includes(name));
  if (missing.length || stale.length) throw Error('Test manifest mismatch. Unregistered: ' + missing.join(', ') + '; missing files: ' + stale.join(', '));
  const names = suite === 'debug' || suite === 'release' ? suites.source.concat(suites[suite]) : suites[suite];
  return names.map(file => ({ file, args: suite === 'debug' && file === 'test-feedback.cjs' ? ['--ui'] : [] }));
}

function main(args) {
  let suite = 'debug', list = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--suite' && args[i + 1]) suite = args[++i];
    else if (args[i] === '--list') list = true;
    else throw Error('Unknown or incomplete argument: ' + args[i]);
  }
  const tests = selectedTests(suite);
  if (list) {
    console.log(tests.map(test => test.file + (test.args.length ? ' ' + test.args.join(' ') : '')).join('\n'));
    console.log('Suite ' + suite + ': ' + tests.length + ' tests');
    return;
  }
  // All legacy adapters receive the same SDK location, including those with an old D: default.
  const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
  const env = { ...process.env, DEVECO_STUDIO_HOME: studio };
  if (suite === 'debug' || suite === 'release') {
    const compiled = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule', suite);
    if (!fs.existsSync(compiled)) throw Error('Build the ' + suite + ' app before running this suite');
  }
  for (const [index, test] of tests.entries()) {
    console.log('[' + (index + 1) + '/' + tests.length + '] ' + test.file);
    const result = spawnSync(process.execPath, [path.join(__dirname, test.file), ...test.args], { cwd: root, env, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw Error(test.file + ' failed: ' + (result.signal || result.status));
  }
  console.log('PASS suite ' + suite + ': ' + tests.length + ' tests');
}

if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error); process.exitCode = 1; }
}
module.exports = { selectedTests };
