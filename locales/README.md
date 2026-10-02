# App localization

`zh-CN.json` and `en.json` are the source of truth for application-owned text.
Message IDs use the original Chinese source text (gettext-style); changing a translation does not require changing call sites. Keep IDs identical in both catalogs.

```ts
import { t } from '../model/I18n';
t('保存');
t('展开全部 {0} 行', [lineCount]);
```

Use whole messages with numbered placeholders when values or word order vary. Keep `{0}`, `{1}`, etc. identical across locales; translators may reorder them. `{{input}}` belongs to prompt templates and is preserved literally. Pass values as arguments rather than interpolating a message ID. Do not translate user messages, model responses, custom prompts, filenames or saved content.

After editing catalogs, run:

```powershell
node scripts/build-locales.cjs
node scripts/build-locales.cjs --check
node scripts/test-i18n-native.cjs
```

The generator checks key parity, placeholders and every literal `t()` reference. It produces `model/LocaleCatalog.ets` for synchronous lookup without platform dependencies. Do not edit the generated file directly. The native adapter test uses the DevEco SDK; set `DEVECO_STUDIO_HOME` if Studio is outside `D:/DevEco Studio`.

Settings offer **Follow system**, **简体中文**, and **English**. Chinese system variants use Simplified Chinese; other languages fall back to English. The device preference lives in `tinybot-ui` Preferences, independently of chat backups and credentials. `EntryAbility` refreshes it on configuration changes and foreground entry. Changing the effective locale rebuilds the view tree while retaining the session ViewModel, navigation stack and saved draft. Model requests and user content are not rewritten.

Module-level label collections must be lazy functions, so they do not freeze the startup language. Generated default chat titles are localized for display; renamed titles and existing messages retain their content. Stored historical errors/tool records remain in their original language, while new errors use the current language. Native system pickers follow the device language. System-visible ability descriptions use native `base` and `zh` resources.

Validation covers locale fallback, explicit overrides, parameter substitution, special characters, catalog parity, persistence across initialization and rollback after save failure. Also verify English layouts on the emulator because longer labels can wrap.
