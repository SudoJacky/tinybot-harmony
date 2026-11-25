import { common } from '@kit.AbilityKit';
import { Diagnostics } from '../model/Diagnostics';
import { preferences } from '@kit.ArkData';
import { i18n } from '@kit.LocalizationKit';
import { AppLanguage, languagePreference, resolveLocale, setLocale } from '../model/I18n';
import { withFileMutation } from './FileMutationQueue';

// UI preferences have their own store and merge into portable backups separately from chat content.
export class LanguagePreferences {
  private static store?: preferences.Preferences;
  private static preference: AppLanguage = 'system';

  static initialize(context: common.Context): void {
    try {
      LanguagePreferences.store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
      LanguagePreferences.preference = languagePreference(String(LanguagePreferences.store.getSync('language', 'system')));
    } catch (error) {
      Diagnostics.log('warn', 'language', 'load_failed', undefined, error as Error);
      LanguagePreferences.preference = 'system';
    }
    LanguagePreferences.refresh();
  }
  static refresh(): void {
    const locale = resolveLocale(LanguagePreferences.preference, i18n.System.getSystemLanguage());
    setLocale(locale);
    AppStorage.setOrCreate('tinybot.language', LanguagePreferences.preference);
    AppStorage.setOrCreate('tinybot.locale', locale);
  }
  static async select(value: AppLanguage): Promise<void> {
    const store = LanguagePreferences.store;
    if (!store) { throw new Error('Language preference storage is unavailable.'); }
    await withFileMutation('preferences:tinybot-ui', async () => {
      const previous = LanguagePreferences.preference;
      if (value === previous) { return; }
      const mark = Diagnostics.begin();
      try { await store.put('language', value); await store.flush(); }
      catch (error) {
        Diagnostics.log('error', 'language', 'save_failed', undefined, error as Error);
        await store.put('language', previous);
        await store.flush();
        throw error as Error;
      } finally { if (Diagnostics.recording) { Diagnostics.end('language.save', mark); } }
      LanguagePreferences.preference = value;
      LanguagePreferences.refresh();
    });
  }
}
