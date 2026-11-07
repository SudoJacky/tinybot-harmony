// Shared only by packaged built-ins. All writes use the existing revision-checked card storage.
const $ = id => document.getElementById(id);
let context = tinybot.panel.context, snapshot = { value: null, revision: 'initial' }, ready = false, saving = false;
let paint, validateState;
const tr = (zh, en) => context.locale.startsWith('zh') ? zh : en;
function localize() {
  document.querySelectorAll('[data-zh]').forEach(el => { el.textContent = tr(el.dataset.zh, el.dataset.en); });
  document.querySelectorAll('[data-aria-zh]').forEach(el => { el.setAttribute('aria-label', tr(el.dataset.ariaZh, el.dataset.ariaEn)); });
}
function controls() { document.querySelectorAll('button,input').forEach(el => { el.disabled = !ready || saving; }); }
function status(message) { $('status').textContent = message; }
async function initialize(render, validate) {
  paint = render; validateState = validate; localize(); render(); controls();
  tinybot.panel.onUpdate(next => { context = next; localize(); render(); controls(); });
  try { const loaded = await tinybot.storage.load(); validate(loaded.value); snapshot = loaded; ready = true; }
  catch (error) { status(error.message); }
  render(); controls();
}
async function commit(value) {
  if (!ready || saving) return false;
  validateState(value); saving = true; status(''); controls();
  let saved = false;
  try { snapshot = await tinybot.storage.save(value, snapshot.revision); saved = true; }
  catch (error) {
    status(error.message);
    try { const loaded = await tinybot.storage.load(); validateState(loaded.value); snapshot = loaded; }
    catch (reloadError) { ready = false; status(error.message + '\n' + reloadError.message); }
  } finally { saving = false; paint(); controls(); }
  return saved;
}
function invalidState() { throw new Error(tr('卡片数据格式不正确，请检查卡片存储。', 'Invalid card data. Check the card storage.')); }
