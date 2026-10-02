import { afterEach, describe, expect, it } from '@ohos/hypium';
import { getLocale, languagePreference, resolveLocale, setLocale, t } from '../main/ets/model/I18n';
import { teamStatus } from '../main/ets/model/Team';
import { EN_MESSAGES, ZH_MESSAGES } from '../main/ets/model/LocaleCatalog';

export default function i18nTests(): void {
  describe('I18n', () => {
    afterEach(() => { setLocale('zh-CN'); });
    it('resolvesSystemLanguageAndExplicitOverrides', 0, () => {
      expect(resolveLocale('system', 'zh-Hans-CN')).assertEqual('zh-CN');
      expect(resolveLocale('system', 'zh_TW')).assertEqual('zh-CN');
      expect(resolveLocale('system', 'en-GB')).assertEqual('en');
      expect(resolveLocale('system', 'fr-FR')).assertEqual('en');
      expect(resolveLocale('en', 'zh-CN')).assertEqual('en');
      expect(resolveLocale('zh-CN', 'en-US')).assertEqual('zh-CN');
      expect(languagePreference('invalid')).assertEqual('system');
    });
    it('updatesLabelsAndTeamStatusesWithoutChangingIdentifiers', 0, () => {
      setLocale('en-US');
      expect(getLocale()).assertEqual('en');
      expect(t('保存')).assertEqual('Save');
      expect(teamStatus('running')).assertEqual('Running');
      setLocale('zh-CN');
      expect(t('保存')).assertEqual('保存');
      expect(teamStatus('running')).assertEqual('执行中');
    });
    it('formatsArgumentsWithoutInterpretingTheirContents', 0, () => {
      setLocale('en');
      expect(t('{0} · {1} 个模型', ['$&{1}', 3])).assertEqual('$&{1} · 3 models');
      expect(t('展开全部 {0} 行', [20])).assertEqual('Expand all 20 lines');
      expect(t('插入 {{input}} 占位')).assertEqual('Insert {{input}}');
      expect(t('Unknown message {0}')).assertEqual('Unknown message {0}');
    });
    it('hasCompleteBilingualCatalogs', 0, () => {
      expect(Object.keys(EN_MESSAGES).length).assertEqual(Object.keys(ZH_MESSAGES).length);
      for (const key of Object.keys(ZH_MESSAGES)) {
        expect(typeof EN_MESSAGES[key]).assertEqual('string');
        expect(/[\u4e00-\u9fff]/.test(EN_MESSAGES[key])).assertFalse();
      }
    });
  });
}
