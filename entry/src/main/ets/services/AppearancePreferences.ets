import { Diagnostics } from '../model/Diagnostics';
import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ThemeControl } from '@kit.ArkUI';
import { AppearanceOptions, accentPalette, defaultAppearance, validateAppearance } from '../model/Appearance';
import { makeAppearanceStyle } from '../common/AppearanceStyle';

// Device preferences are separate from conversations and model settings.
export class AppearancePreferences {
  private static store?: preferences.Preferences;
  private static context?: common.UIAbilityContext;
  private static options: AppearanceOptions = defaultAppearance();
  private static active: boolean = false;
  private static themeKey: string = '';
  private static publishedOptions?: AppearanceOptions;
  private static publishedDark?: boolean;

  static initialize(context: common.UIAbilityContext): void {
    AppearancePreferences.active = false;
    AppearancePreferences.themeKey = '';
    AppearancePreferences.publishedOptions = undefined;
    AppearancePreferences.publishedDark = undefined;
    AppearancePreferences.context = context;
    const store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
    AppearancePreferences.store = store;
    const serialized = store.getSync('appearance', '') as string;
    const options = serialized ? JSON.parse(serialized) as AppearanceOptions : defaultAppearance();
    validateAppearance(options);
    AppearancePreferences.options = options;
    // Apply window-affecting configuration before loadContent creates the first ArkUI frame.
    AppearancePreferences.apply(options);
    Diagnostics.log('info', 'appearance', 'loaded');
  }

  static activate(): void {
    AppearancePreferences.active = true;
    AppearancePreferences.themeKey = '';
    // ThemeControl needs ArkUI content; do not reconfigure the window during the splash handoff.
    AppearancePreferences.refresh();
  }

  private static apply(options: AppearanceOptions, previous?: AppearanceOptions): void {
    const context = AppearancePreferences.context;
    if (!context) { throw new Error('Appearance context is unavailable.'); }
    const application = context.getApplicationContext();
    if (previous?.mode !== options.mode) {
      application.setColorMode(options.mode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
        options.mode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
    if (previous?.fontScale !== options.fontScale) { application.setFontSizeScale(options.fontScale); }
    AppearancePreferences.refresh();
  }

  static refresh(config?: Configuration): void {
    const options = AppearancePreferences.options;
    const colorMode = config?.colorMode === undefined ? AppearancePreferences.context?.config.colorMode : config.colorMode;
    const dark = options.mode === 'dark' || (options.mode === 'system' &&
      colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    const themeKey = options.accent === 'custom' ? options.customColor : options.accent;
    if (AppearancePreferences.active && AppearancePreferences.themeKey !== themeKey) {
      const lightPalette = accentPalette(options.accent, false, options.customColor);
      const darkPalette = accentPalette(options.accent, true, options.customColor);
      ThemeControl.setDefaultTheme({ colors: { brand: lightPalette.accent }, darkColors: { brand: darkPalette.accent } });
      AppearancePreferences.themeKey = themeKey;
    }
    if (AppearancePreferences.publishedOptions === options && AppearancePreferences.publishedDark === dark) { return; }
    AppStorage.setOrCreate('tinybot.appearance.options', options);
    AppStorage.setOrCreate('tinybot.appearance.dark', dark);
    AppStorage.setOrCreate('tinybot.appearance.style', makeAppearanceStyle(options, dark));
    AppearancePreferences.publishedOptions = options;
    AppearancePreferences.publishedDark = dark;
  }

  static select(options: AppearanceOptions): void {
    validateAppearance(options);
    const store = AppearancePreferences.store;
    if (!store || !AppearancePreferences.active) { throw new Error('Appearance storage is unavailable.'); }
    const previous = AppearancePreferences.options;
    const serialized = JSON.stringify(options);
    try {
      store.putSync('appearance', serialized);
      store.flushSync();
      AppearancePreferences.options = JSON.parse(serialized) as AppearanceOptions;
      AppearancePreferences.apply(AppearancePreferences.options, previous);
    } catch (error) {
      Diagnostics.log('error', 'appearance', 'save_failed', undefined, error as Error);
      const attempted = AppearancePreferences.options;
      AppearancePreferences.options = previous;
      store.putSync('appearance', JSON.stringify(previous));
      store.flushSync();
      AppearancePreferences.apply(previous, attempted);
      throw new Error((error as Error).message);
    }
    Diagnostics.log('info', 'appearance', 'applied');
  }
}
