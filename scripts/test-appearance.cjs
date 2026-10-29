// Exercise the actual palette, material cache, and device-preference service without a UI emulator.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve('entry/src/main/ets'), modules = new Map(), storage = new Map(), events = [], logs = [];
let disk = new Map(), working = new Map(), failFlush = false, failApply = false, deviceLevel = 0, levelReads = 0;
// The runtime API level decides whether the immersive-material module exists at all.
let deviceSdk = 26;
const store = { getSync: (key, fallback) => working.has(key) ? working.get(key) : fallback,
  putSync: (key, value) => working.set(key, value), flushSync() {
    if (failFlush) { failFlush = false; throw Error('disk write failed'); }
    disk = new Map(working);
  } };
class Material { static empty = { empty: true }; }
class ImmersiveMaterial extends Material { constructor(options) { super(); this.options = options; } }
const uiMaterial = { Material, ImmersiveMaterial, ImmersiveStyle: { THICK: 3, THIN: 1, ULTRA_THIN: 0 },
  MaterialLevel: { EXQUISITE: 0, GENTLE: 1, SMOOTH: 2 }, getGlobalMaterialLevel: () => { levelReads++; return deviceLevel; } };
const colorModes = { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1, COLOR_MODE_NOT_SET: -1 };
const kits = { '@kit.BasicServicesKit': { deviceInfo: { get sdkApiVersion() { return deviceSdk; } } },
  '@kit.ArkUI': { uiMaterial, ThemeControl: { setDefaultTheme: value => events.push(['theme', value]) } },
  '@kit.ArkData': { preferences: { getPreferencesSync: () => store } },
  '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: colorModes } },
  '@kit.PerformanceAnalysisKit': { hilog: { info: (...args) => logs.push(args), error: (...args) => logs.push(args) } } };
function load(file, cache = modules) {
  file = path.resolve(file); if (cache.has(file)) return cache.get(file);
  const loaded = { exports: {}, Observed: value => value, $r: name => name, Color: { Transparent: 'transparent' },
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    require: name => kits[name] || load(path.resolve(path.dirname(file), name + '.ets'), cache) };
  cache.set(file, loaded.exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
  }).outputText, loaded, { filename: file });
  return loaded.exports;
}
load(root + '/model/Diagnostics.ets').Diagnostics.configureLogSink(data => logs.push(data));
const model = load(root + '/model/Appearance.ets');
for (const [hue, color] of [[0, '#FF0000'], [60, '#FFFF00'], [120, '#00FF00'], [180, '#00FFFF'],
  [240, '#0000FF'], [300, '#FF00FF'], [360, '#FF0000']]) {
  assert.equal(model.hsvColor(hue, 1, 1), color, 'Hue spectrum');
}
for (let red = 0; red <= 255; red += 51) for (let green = 0; green <= 255; green += 51)
  for (let blue = 0; blue <= 255; blue += 51) {
    const color = model.rgbColor(red, green, blue), hsv = model.colorHsv(color);
    assert.equal(model.hsvColor(hsv.hue, hsv.saturation, hsv.value), color, 'HEX/palette round trip');
  }
for (const neutral of ['#000000', '#808080', '#FFFFFF']) {
  const hsv = model.colorHsv(neutral, 210);
  assert.equal(hsv.hue, 210, 'Neutral colors retain the selected hue');
  assert.equal(model.hsvColor(hsv.hue, hsv.saturation, hsv.value), neutral);
}
assert.throws(() => model.colorHsv('#invalid'), /Invalid custom color/);
for (const name of model.ACCENT_NAMES) for (const dark of [false, true]) {
  for (const custom of ['#000000', '#FFFFFF', '#FFFF00', '#00FF00', '#0000FF', '#FAF8EE', '#123456']) {
    const palette = model.accentPalette(name, dark, custom);
    assert.ok(model.colorContrast(palette.accent, palette.onAccent) >= 4.5, name + ' button contrast');
    assert.ok(model.colorContrast(palette.container, palette.onContainer) >= 4.5, name + ' text contrast');
  }
}
for (const patch of [{ mode: 'invalid' }, { fontScale: 8 }, { accent: 'invalid' }, { customColor: '#GG0000' },
  { lightEffect: 'invalid' }, { fontFamily: 42 }]) {
  assert.throws(() => model.validateAppearance({ ...model.defaultAppearance(), ...patch }), /Invalid/);
}
const { AppearancePreferences: preferences } = load(root + '/services/AppearancePreferences.ets');
const { currentAppearanceStyle } = load(root + '/common/AppearanceStyle.ets');
const application = { setColorMode: value => events.push(['mode', value]), setFontSizeScale(value) {
  if (failApply) { failApply = false; throw Error('apply failed'); }
  events.push(['fontScale', value]);
} };
const context = { config: { colorMode: colorModes.COLOR_MODE_LIGHT }, getApplicationContext: () => application };
preferences.initialize(context);
assert.deepEqual(events.map(([type]) => type), ['mode', 'fontScale'], 'Prepare window configuration before the first page');
preferences.activate();
assert.deepEqual(events.map(([type]) => type), ['mode', 'fontScale', 'theme'], 'Mounting only applies the ArkUI theme, without resizing the first frame');
assert.equal(currentAppearanceStyle().accent, '#216451');
assert.equal(currentAppearanceStyle().controlBackground, 'transparent', 'API 26 keeps its material backing');
const defaultMaterial = currentAppearanceStyle().control;
const menuMaterial = currentAppearanceStyle().menu;
assert.equal(menuMaterial.options.style, uiMaterial.ImmersiveStyle.THIN);
assert.equal(menuMaterial.options.colorInvert, true);
assert.equal(currentAppearanceStyle().noMaterial, Material.empty);
const readingMaterial = currentAppearanceStyle().readingSurface;
assert.equal(readingMaterial.options.style, uiMaterial.ImmersiveStyle.THICK);
assert.equal(readingMaterial.options.materialColor, 'app.color.reading_surface_tint');
assert.equal(readingMaterial.options.colorInvert, false);
preferences.refresh(); assert.equal(currentAppearanceStyle().control, defaultMaterial, 'Do not recreate unchanged materials');
assert.equal(currentAppearanceStyle().readingSurface, readingMaterial, 'Reuse the long-sheet material');
assert.equal(currentAppearanceStyle().menu, menuMaterial, 'Reuse unchanged adaptive menu material');
const selected = { ...model.defaultAppearance(), mode: 'dark', accent: 'custom', customColor: '#FAF8EE',
  fontScale: 1.3, fontFamily: 'Noto Serif', lightEffect: 'off' };
preferences.select(selected);
// API 26 needs an explicit empty material: undefined restores the component's default effect.
assert.equal(currentAppearanceStyle().control, Material.empty);
assert.equal(currentAppearanceStyle().surface, Material.empty);
assert.equal(currentAppearanceStyle().menu, Material.empty);
assert.equal(currentAppearanceStyle().readingSurface, Material.empty);
assert.equal(currentAppearanceStyle().accentControl, Material.empty);
const { systemMaterialAttribute, menuMaterialAttribute } = load(root + '/common/MaterialAttributes.ets');
const optionColors = [];
const colorMethods = {
  optionFontColor: value => optionColors.push(['text', value]),
  selectedOptionFontColor: value => optionColors.push(['selectedText', value]),
  selectedOptionBgColor: value => optionColors.push(['selectedBackground', value])
};
const applied = [], nativeControl = { ...colorMethods, systemMaterial: value => applied.push(['control', value]),
  menuSystemMaterial: value => applied.push(['menu', value]) };
systemMaterialAttribute(defaultMaterial).applyNormalAttribute(nativeControl);
systemMaterialAttribute(currentAppearanceStyle().control).applyNormalAttribute(nativeControl);
menuMaterialAttribute(currentAppearanceStyle().menu).applyNormalAttribute(nativeControl);
assert.equal(applied[1][1], Material.empty, 'Turning off clears material on an existing node');
assert.equal(applied[2][1], Material.empty, 'Select menus explicitly turn off too');
assert.deepEqual(optionColors, [['text', 'sys.color.font_primary'], ['selectedText', 'sys.color.font_primary'],
  ['selectedBackground', 'sys.color.comp_background_tertiary']], 'Option text uses adaptive system colors');
assert.equal(currentAppearanceStyle().effectStrength, 0);
assert.equal(currentAppearanceStyle().fontFamily, 'Noto Serif');
assert.ok(events.some(([type, value]) => type === 'mode' && value === colorModes.COLOR_MODE_DARK));
assert.ok(events.some(([type, value]) => type === 'fontScale' && value === 1.3));
assert.deepEqual(JSON.parse(disk.get('appearance')), selected);
for (const failure of ['flush', 'apply']) {
  if (failure === 'flush') failFlush = true; else failApply = true;
  assert.throws(() => preferences.select({ ...selected, accent: 'blue' }), /failed/);
  assert.deepEqual(JSON.parse(disk.get('appearance')), selected, 'Failed changes must restore the saved preferences');
  assert.equal(storage.get('tinybot.appearance.options').accent, 'custom');
  assert.ok(logs.some(data => data.level === 'error' && data.module === 'appearance' && data.event === 'save_failed'));
}
working = new Map(disk);
const restoreStart = events.length;
preferences.initialize(context);
assert.deepEqual(events.slice(restoreStart), [['mode', colorModes.COLOR_MODE_DARK], ['fontScale', 1.3]], 'Restore saved dark mode and font scale before mounting');
preferences.activate();
assert.equal(currentAppearanceStyle().fontFamily, 'Noto Serif', 'Restore preferences on the next launch');
preferences.select({ ...model.defaultAppearance(), mode: 'system', accent: 'blue', lightEffect: 'gentle' });
preferences.refresh({ colorMode: colorModes.COLOR_MODE_DARK });
assert.equal(currentAppearanceStyle().accent, model.accentPalette('blue', true).accent);
assert.equal(currentAppearanceStyle().control.options.style, uiMaterial.ImmersiveStyle.THICK);
assert.equal(currentAppearanceStyle().control.options.interactive, false);
assert.equal(currentAppearanceStyle().control.options.lightEffect.color, '#40FFFFFF');
preferences.select({ ...model.defaultAppearance(), lightEffect: 'vivid' });
assert.equal(currentAppearanceStyle().control.options.style, uiMaterial.ImmersiveStyle.ULTRA_THIN);
assert.equal(currentAppearanceStyle().control.options.interactive, true);
assert.equal(currentAppearanceStyle().readingSurface.options.style, uiMaterial.ImmersiveStyle.THICK, 'Long-sheet legibility also holds in vivid mode');
preferences.select(model.defaultAppearance());
assert.equal(currentAppearanceStyle().accent, '#216451');
assert.equal(currentAppearanceStyle().effectStrength, 1);
for (const [level, controlStyle, surfaceStyle] of [
  [uiMaterial.MaterialLevel.EXQUISITE, uiMaterial.ImmersiveStyle.ULTRA_THIN, uiMaterial.ImmersiveStyle.THIN],
  [uiMaterial.MaterialLevel.GENTLE, uiMaterial.ImmersiveStyle.THIN, uiMaterial.ImmersiveStyle.THICK],
  [uiMaterial.MaterialLevel.SMOOTH, uiMaterial.ImmersiveStyle.THICK, uiMaterial.ImmersiveStyle.THICK]
]) {
  deviceLevel = level;
  const before = levelReads;
  const { AppMaterials } = load(root + '/common/AppMaterials.ets', new Map());
  AppMaterials.configure('auto', '#216451');
  assert.equal(AppMaterials.control.options.style, controlStyle, 'Controls retain the device tier');
  assert.equal(AppMaterials.accentControl.options.style, controlStyle, 'Accent buttons retain the device tier');
  assert.equal(AppMaterials.surface.options.style, surfaceStyle, 'Expanded surfaces use a gentler tier with a floor');
  assert.equal(AppMaterials.surface, AppMaterials.surface, 'Reuse the expanded-surface material');
  assert.equal(levelReads, before + 1, 'All roles share one device capability query');
  for (const [effect, control, surface] of [
    ['vivid', uiMaterial.ImmersiveStyle.ULTRA_THIN, uiMaterial.ImmersiveStyle.THIN],
    ['standard', uiMaterial.ImmersiveStyle.THIN, uiMaterial.ImmersiveStyle.THICK],
    ['gentle', uiMaterial.ImmersiveStyle.THICK, uiMaterial.ImmersiveStyle.THICK]
  ]) {
    const previous = AppMaterials.surface;
    AppMaterials.configure(effect, '#216451');
    assert.equal(AppMaterials.control.options.style, control);
    assert.equal(AppMaterials.surface.options.style, surface);
    assert.notEqual(AppMaterials.surface, previous, 'Changed settings replace cached surfaces');
    assert.equal(AppMaterials.readingSurface.options.style, uiMaterial.ImmersiveStyle.THICK);
  }
  AppMaterials.configure('off', '#216451');
  for (const role of ['control', 'accentControl', 'surface', 'menu', 'empty', 'readingSurface']) assert.equal(AppMaterials[role], Material.empty);
}

// API 20: the native uiMaterial module does not exist. Every read of the namespace must be
// skipped, not merely tolerated, so a throwing stand-in replaces it while these modules load.
deviceSdk = 20;
const throwingMaterial = new Proxy({}, { get(_target, property) {
  throw new Error('uiMaterial.' + String(property) + ' must never be read on API 20');
} });
const api26Kit = kits['@kit.ArkUI'];
kits['@kit.ArkUI'] = { ...api26Kit, uiMaterial: throwingMaterial };
const lowLevels = new Map();
const lowStyleModule = load(root + '/common/AppearanceStyle.ets', lowLevels);
const lowMaterials = load(root + '/common/AppMaterials.ets', lowLevels).AppMaterials;
assert.equal(lowMaterials.available, false, 'API 20 reports no immersive material');
for (const role of ['control', 'accentControl', 'surface', 'menu', 'empty', 'readingSurface']) {
  assert.equal(lowMaterials[role], undefined, 'API 20 resolves ' + role + ' without touching uiMaterial');
}
const low = lowStyleModule.makeAppearanceStyle(model.defaultAppearance(), false);
assert.equal(low.accent, '#216451', 'Plain palette stays complete without material');
assert.equal(low.onAccent, '#FFFFFF');
assert.equal(low.effectStrength, 1);
assert.equal(low.materialAvailable, false);
assert.equal(low.controlBackground, 'app.color.surface_variant', 'Unsupported material gets an opaque themed control backing');
assert.equal(low.control, undefined);
assert.equal(low.readingSurface, undefined);
const lowDark = lowStyleModule.makeAppearanceStyle({ ...model.defaultAppearance(), mode: 'dark', accent: 'blue' }, true);
assert.equal(lowDark.accent, model.accentPalette('blue', true).accent, 'Dark accent palette survives without material');
assert.equal(lowDark.controlBackground, 'app.color.surface_variant', 'Dark controls resolve the dark theme resource');
const lowOff = lowStyleModule.makeAppearanceStyle({ ...model.defaultAppearance(), lightEffect: 'off' }, false);
assert.equal(lowOff.effectStrength, 0);
assert.equal(lowOff.control, undefined);
const forbiddenNative = new Proxy(colorMethods, { get(target, property) {
  if (Object.hasOwn(target, property)) return target[property];
  throw Error('API 26 component method read on API 20');
} });
systemMaterialAttribute(lowOff.control).applyNormalAttribute(forbiddenNative);
optionColors.length = 0;
menuMaterialAttribute(lowOff.menu).applyNormalAttribute(forbiddenNative);
assert.equal(optionColors.length, 3, 'Plain API 20 menus still receive supported option colors');
for (const effect of ['auto', 'gentle', 'standard', 'vivid']) {
  lowMaterials.configure(effect, '#216451');
  assert.equal(lowMaterials.surface, undefined, 'Saved light-sense preference never materialises on API 20');
}
kits['@kit.ArkUI'] = api26Kit;
deviceSdk = 26;
console.log('PASS appearance: preset/custom contrast, validation, persistence, save/apply rollback, system mode, material levels/cache, reset and API 20 plain interface');
