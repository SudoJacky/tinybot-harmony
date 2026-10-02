import { t } from '../model/I18n';
import { AppLanguage } from '../model/I18n';
import { LanguagePreferences } from '../services/LanguagePreferences';
import { ChatViewModel, SettingsViewModel } from '../viewmodel/ChatViewModel';
import { ProviderInfo } from '../model/Provider';
import { ProviderProfile } from '../model/ProviderProfiles';
import { Btn, Font, Space, Styles, protocolName } from '../common/Theme';
import { Banner, BottomBar, GroupCard, NavRow, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

@Component
export struct SettingsPanel {
  @StorageProp('tinybot.language') private language: string = 'system';
  @State private languageError: string = '';
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onEditProvider: (id: string, preset: string) => void = () => {};
  onSkills: () => void = () => {};
  onPrompt: () => void = () => {};

  // Toggles persist immediately; revert the switch when the save fails.
  private async saveToggle(apply: (value: boolean) => void, value: boolean): Promise<void> {
    apply(value);
    if (!await this.app.saveSettings()) { apply(!value); }
  }

  private promptPreview(): string {
    const prompt = this.app.config.systemPrompt.trim();
    return prompt.length > 0 ? prompt.replace(/\s+/g, ' ') : t("未设置，使用默认行为");
  }

  build() {
    Scroll() {
      Column() {
        SectionHeader({ title: t('语言') })
        GroupCard() {
          Column() {
            ForEach(['system', 'zh-CN', 'en'], (choice: string, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: choice === 'system' ? t('跟随系统') : choice === 'zh-CN' ? '简体中文' : 'English',
                value: this.language === choice ? '✓' : '', compId: 'language-' + choice,
                disabled: this.app.busy, onTap: async () => {
                  await this.app.flushDraft();
                  if (this.app.saveError) { return; }
                  try { LanguagePreferences.select(choice as AppLanguage); }
                  catch (_) { this.languageError = t('无法保存语言设置，请重试。'); }
                } })
            }, (choice: string) => choice)
          }
        }
        if (this.languageError) { Banner({ text: this.languageError }) }
        SectionHeader({ title: t("模型服务") })
        GroupCard() {
          Column() {
            ForEach(this.app.providerProfiles, (profile: ProviderProfile) => {
              NavRow({ title: profile.name, compId: 'edit-provider-' + profile.id, icon: $r('sys.symbol.cloud'),
                subtitle: t("{0} · {1} 个模型", [protocolName(profile.protocol), profile.models.length]),
                value: profile.enabled ? '' : t("已停用"), disabled: this.app.busy,
                onTap: () => this.onEditProvider(profile.id, '') })
              RowDivider()
            }, (profile: ProviderProfile) => JSON.stringify(profile))
            NavRow({ title: t("添加自定义服务"), compId: 'add-provider', icon: $r('sys.symbol.plus'), accent: true,
              disabled: this.app.busy, onTap: () => this.onEditProvider('', '') })
          }
        }
        SectionHeader({ title: t("快速添加") })
        GroupCard() {
          Column() {
            ForEach(this.app.providerPresets, (preset: ProviderInfo, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: preset.name, subtitle: protocolName(preset.protocol), compId: 'preset-' + preset.id,
                disabled: this.app.busy, onTap: () => this.onEditProvider('', preset.id) })
            }, (preset: ProviderInfo) => preset.id)
          }
        }
        SectionHeader({ title: t("助手") })
        GroupCard() {
          Column() {
            NavRow({ title: t("系统提示"), subtitle: this.promptPreview(), compId: 'open-system-prompt',
              icon: $r('sys.symbol.square_and_pencil'), disabled: this.app.busy, onTap: () => this.onPrompt() })
            RowDivider()
            NavRow({ title: 'Skills', compId: 'open-skills', icon: $r('sys.symbol.wand_and_stars'),
              value: t("{0} 个已启用", [this.app.extensions.skills.filter((skill) => skill.enabled).length]),
              disabled: this.app.busy || this.app.saveError.length > 0, onTap: () => this.onSkills() })
            RowDivider()
            SwitchRow({ title: t("允许读取网页"), compId: 'web-enabled', isOn: this.settings.webEnabled,
              subtitle: t("读取指定链接的静态正文，内容会发送给当前模型。"), disabled: this.app.busy,
              onChange: (value: boolean) => { this.saveToggle((v: boolean) => { this.settings.webEnabled = v; }, value); } })
            RowDivider()
            SwitchRow({ title: t("自动压缩历史"), compId: 'auto-compact', isOn: this.settings.autoCompact,
              subtitle: t("接近上下文预算时，用当前模型生成摘要，完整记录保留。"), disabled: this.app.busy,
              onChange: (value: boolean) => { this.saveToggle((v: boolean) => { this.settings.autoCompact = v; }, value); } })
          }
        }
        if (this.settings.error.length > 0) {
          Banner({ text: this.settings.error, compId: 'settings-error' }).margin({ top: Space.md })
        } else if (this.app.error.length > 0) {
          Banner({ text: this.app.error, compId: 'provider-list-error' }).margin({ top: Space.md })
        }
        Text(t("会话与文件保存在本机 · 消息和工具结果会发送给所选模型服务"))
          .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
          .width('100%').margin({ top: Space.xl })
      }.padding({ left: Space.page, right: Space.page, bottom: Space.xl }).width('100%')
    }.height('100%').width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
  }
}

@Component
export struct SystemPromptPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onSaved: () => void = () => {};

  build() {
    Column() {
      Column({ space: Space.md }) {
        TextArea({ text: this.settings.systemPrompt, placeholder: t("希望 Tinybot 如何回答？") }).id('system-prompt')
          .attributeModifier(Styles.area).layoutWeight(1).maxLength(4000).showCounter(true)
          .backgroundColor($r('app.color.surface'))
          .onChange((value: string) => { this.settings.systemPrompt = value; })
        if (this.settings.error.length > 0) {
          Banner({ text: this.settings.error })
        }
      }.layoutWeight(1).padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.md })
      BottomBar() {
        Button(this.app.busy ? t("正在保存…") : t("保存")).id('save-settings').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.busy)
          .onClick(async () => { if (await this.app.saveSettings()) { this.onSaved(); } })
      }
    }.width('100%').height('100%')
  }
}
