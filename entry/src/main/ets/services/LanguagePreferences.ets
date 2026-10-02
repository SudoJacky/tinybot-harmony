import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { i18n } from '@kit.LocalizationKit';
import { AppLanguage, languagePreference, resolveLocale, setLocale } from '../model/I18n';

// Device UI preference: deliberately separate from chat content, model configuration and backups.
export class LanguagePreferences {
  private static store?: preferences.Preferences;
  private static preference: AppLanguage = 'system';

  static initialize(context: common.Context): void {
    try {
      LanguagePreferences.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
      LanguagePreferences.preference = languagePreference(String(LanguagePreferences.store.getSync('language', 'system')));
    } catch (_) { LanguagePreferences.preference = 'system'; }
    LanguagePreferences.refresh();
  }
  static refresh(): void {
    const locale = resolveLocale(LanguagePreferences.preference, i18n.System.getSystemLanguage());
    setLocale(locale);
    AppStorage.setOrCreate('tinybot.language', LanguagePreferences.preference);
    AppStorage.setOrCreate('tinybot.locale', locale);
  }
  static select(value: AppLanguage): void {
    const store = LanguagePreferences.store;
    if (!store) { throw new Error('Language preference storage is unavailable.'); }
    const previous = LanguagePreferences.preference;
    try { store.putSync('language', value); store.flushSync(); }
    catch (error) {
      store.putSync('language', previous);
      throw new Error((error as Error).message);
    }
    LanguagePreferences.preference = value;
    LanguagePreferences.refresh();
  }
}
