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
  @State private showLanguage: boolean = false;
  @State private showPresets: boolean = false;
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onEditProvider: (id: string, preset: string) => void = () => {};
  onSkills: () => void = () => {};
  onPrompt: () => void = () => {};
  private pendingSave: Promise<void> = Promise.resolve();

  // A brief save leaves the page untouched; a reply, compaction or team run locks it with a notice.
  private blocked(): boolean { return this.app.busy && !this.app.saving; }
  // Editors need a mutable session; unsaved chat data must be resolved first.
  private canEdit(): boolean { return !this.blocked() && this.app.saveError.length === 0; }

  // Toggles persist immediately, one save at a time; a failed save reverts the switch and says why.
  private saveToggle(apply: (value: boolean) => void, value: boolean): void {
    apply(value);
    this.pendingSave = this.pendingSave.then(async () => {
      if (await this.app.saveSettings()) { return; }
      apply(!value);
      this.getUIContext().getPromptAction().showToast({ message: this.settings.error });
    });
  }

  private promptPreview(): string {
    const prompt = this.app.config.systemPrompt.trim();
    return prompt.length > 0 ? prompt.replace(/\s+/g, ' ') : t("未设置，使用默认行为");
  }

  private languageName(choice: string): string {
    return choice === 'system' ? t('跟随系统') : choice === 'zh-CN' ? '简体中文' : 'English';
  }

  @Builder
  languageSheet() {
    Column() {
      GroupCard() {
        Column() {
          ForEach(['system', 'zh-CN', 'en'], (choice: string, index: number) => {
            if (index > 0) { RowDivider() }
            NavRow({ title: this.languageName(choice), trailing: 'select', active: this.language === choice,
              compId: 'language-' + choice, disabled: !this.canEdit(), onTap: async () => {
                await this.app.flushDraft();
                if (this.app.saveError) { return; }
                try { LanguagePreferences.select(choice as AppLanguage); this.languageError = ''; this.showLanguage = false; }
                catch (_) { this.languageError = t('无法保存语言设置，请重试。'); }
              } })
          }, (choice: string) => choice)
        }
      }
      if (this.languageError) { Banner({ text: this.languageError }).margin({ top: Space.md }) }
    }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
  }
  private choosePreset(id: string): void {
    this.showPresets = false;
    setTimeout(() => this.onEditProvider('', id), 250);
  }
  @Builder
  presetsSheet() {
    Scroll() {
      Column() {
        Text(t('选择服务后，地址和常用模型会自动填好。')).fontSize(13).fontColor($r('app.color.text_secondary'))
          .width('100%').padding({ bottom: 12 })
        GroupCard() {
          Column() {
            ForEach(this.app.providerPresets, (preset: ProviderInfo, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: preset.name, subtitle: protocolName(preset.protocol), compId: 'preset-' + preset.id,
                disabled: !this.canEdit(), onTap: () => this.choosePreset(preset.id) })
            }, (preset: ProviderInfo) => preset.id)
            RowDivider()
            NavRow({ title: t('添加自定义服务'), compId: 'add-custom-provider', icon: $r('sys.symbol.plus'), accent: true,
              disabled: !this.canEdit(), onTap: () => this.choosePreset('') })
          }
        }
      }.width('100%').padding(Space.page)
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Auto)
  }

  @Builder
  statusBanners() {
    if (this.blocked()) {
      Banner({ text: t('有任务正在进行，完成后可修改设置。'), danger: false, icon: $r('sys.symbol.clock'), compId: 'settings-busy' })
        .margin({ top: Space.sm })
    }
    if (this.app.saveError.length > 0) {
      Banner({ text: this.app.saveError, compId: 'settings-save-error' }).margin({ top: Space.sm })
    } else if (this.settings.error.length > 0) {
      Banner({ text: this.settings.error, compId: 'settings-error' }).margin({ top: Space.sm })
    } else if (this.app.error.length > 0) {
      Banner({ text: this.app.error, compId: 'provider-list-error' }).margin({ top: Space.sm })
    }
  }

  build() {
    Scroll() {
      Column() {
        this.statusBanners()
        SectionHeader({ title: t("模型服务") })
        GroupCard() {
          Column() {
            ForEach(this.app.providerProfiles, (profile: ProviderProfile) => {
              NavRow({ title: profile.name, compId: 'edit-provider-' + profile.id, icon: $r('sys.symbol.cloud'),
                subtitle: t("{0} · {1} 个模型", [protocolName(profile.protocol), profile.models.length]),
                value: profile.enabled ? '' : t("已停用"), muted: !profile.enabled, disabled: !this.canEdit(),
                onTap: () => this.onEditProvider(profile.id, '') })
              RowDivider()
            }, (profile: ProviderProfile) => JSON.stringify(profile))
            NavRow({ title: t('添加模型服务'), compId: 'add-provider', icon: $r('sys.symbol.plus'), accent: true,
              disabled: !this.canEdit(), onTap: () => { this.showPresets = true; } })
          }
        }
        SectionHeader({ title: t("助手") })
        GroupCard() {
          Column() {
            NavRow({ title: t("系统提示"), subtitle: this.promptPreview(), compId: 'open-system-prompt',
              icon: $r('sys.symbol.square_and_pencil'), disabled: !this.canEdit(), onTap: () => this.onPrompt() })
            RowDivider()
            NavRow({ title: 'Skills', compId: 'open-skills', icon: $r('sys.symbol.wand_and_stars'),
              value: t("{0} 个已启用", [this.app.extensions.skills.filter((skill) => skill.enabled).length]),
              disabled: !this.canEdit(), onTap: () => this.onSkills() })
            RowDivider()
            SwitchRow({ title: t("自动压缩历史"), compId: 'auto-compact', isOn: this.settings.autoCompact,
              subtitle: t("接近上下文预算时，用当前模型生成摘要，完整记录保留。"), disabled: !this.canEdit(),
              onChange: (value: boolean) => { this.saveToggle((v: boolean) => { this.settings.autoCompact = v; }, value); } })
          }
        }
        SectionHeader({ title: t('隐私') })
        GroupCard() {
          SwitchRow({ title: t("允许读取网页"), compId: 'web-enabled', isOn: this.settings.webEnabled,
            subtitle: t("读取指定链接的静态正文，内容会发送给当前模型。"), disabled: !this.canEdit(),
            onChange: (value: boolean) => { this.saveToggle((v: boolean) => { this.settings.webEnabled = v; }, value); } })
        }
        SectionHeader({ title: t('偏好设置') })
        GroupCard() {
          NavRow({ title: t('语言'), value: this.languageName(this.language),
            compId: 'open-language', disabled: !this.canEdit(), onTap: () => { this.showLanguage = true; } })
            .bindSheet($$this.showLanguage, this.languageSheet(), { title: { title: t('语言') }, height: SheetSize.FIT_CONTENT,
              dragBar: true, backgroundColor: $r('app.color.page_background') })
        }
        Text(t("会话与文件保存在本机 · 消息和工具结果会发送给所选模型服务"))
          .fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
          .width('100%').margin({ top: Space.xl })
      }.padding({ left: Space.page, right: Space.page, bottom: Space.xl }).width('100%')
    }.height('100%').width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
    .bindSheet($$this.showPresets, this.presetsSheet(), { title: { title: t('添加模型服务') }, detents: [SheetSize.LARGE], dragBar: true,
      backgroundColor: $r('app.color.page_background') })
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
