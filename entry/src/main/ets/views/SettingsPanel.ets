import { t } from '../model/I18n';
import { AppLanguage } from '../model/I18n';
import { LanguagePreferences } from '../services/LanguagePreferences';
import { ChatViewModel, SettingsViewModel } from '../viewmodel/ChatViewModel';
import { ProviderInfo } from '../model/Provider';
import { ProviderProfile } from '../model/ProviderProfiles';
import { AssistantOptions, defaultAssistantOptions } from '../model/AssistantOptions';
import { ProductivityData } from '../model/Productivity';
import { Btn, Font, Space, Styles, protocolName } from '../common/Theme';
import { monochromeProviderLogo, providerLogo } from '../common/ProviderBrand';
import { Banner, BottomBar, GroupCard, NavRow, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

@Component
export struct SettingsPanel {
  @StorageProp('tinybot.language') private language: string = 'system';
  @State private languageError: string = '';
  @State private showLanguage: boolean = false;
  @State private showPresets: boolean = false;
  @State private assistantDraft: AssistantOptions = defaultAssistantOptions();
  @State private assistantSaving: boolean = false;
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onEditProvider: (id: string, preset: string) => void = () => {};
  onSkills: () => void = () => {};
  onUserDocument: () => void = () => {};
  onUsage: () => void = () => {};
  onModels: () => void = () => {};
  onBackup: () => void = () => {};
  onSupport: (page: string) => void = () => {};
  onTools: (tab: string) => void = () => {};
  private pendingSave: Promise<void> = Promise.resolve();

  // A brief save leaves the page untouched; a reply, compaction or team run locks it with a notice.
  private blocked(): boolean { return this.app.busy && !this.app.saving; }
  // Editors need a mutable session; unsaved chat data must be resolved first.
  private canEdit(): boolean { return !this.blocked() && !this.assistantSaving && this.app.saveError.length === 0; }

  aboutToAppear(): void { this.resetAssistantDraft(); }

  private resetAssistantDraft(): void {
    this.assistantDraft = JSON.parse(JSON.stringify(this.app.productivity.options || defaultAssistantOptions())) as AssistantOptions;
  }

  private saveAssistantToggle(kind: string, value: boolean): void {
    if (!this.canEdit()) { return; }
    if (kind === 'memory') { this.assistantDraft.autoMemory = value; }
    else if (kind === 'readOnly') { this.assistantDraft.readOnly = value; }
    else if (kind === 'summary') { this.assistantDraft.saveSummary = value; }
    this.assistantSaving = true;
    this.pendingSave = this.pendingSave.then(async () => {
      try {
        const extras = JSON.parse(JSON.stringify(this.app.productivity)) as ProductivityData;
        const options = extras.options || defaultAssistantOptions();
        if (kind === 'memory') { options.autoMemory = value; }
        else if (kind === 'readOnly') { options.readOnly = value; }
        else if (kind === 'summary') { options.saveSummary = value; }
        extras.options = options;
        if (!await this.app.saveProductivity(extras)) {
          this.getUIContext().getPromptAction().showToast({ message: this.app.error });
        }
      } finally { this.resetAssistantDraft(); this.assistantSaving = false; }
    });
  }

  // Toggles persist immediately, one save at a time; a failed save reverts the switch and says why.
  private saveToggle(apply: (value: boolean) => void, value: boolean): void {
    apply(value);
    this.pendingSave = this.pendingSave.then(async () => {
      if (await this.app.saveSettings()) { return; }
      apply(!value);
      this.getUIContext().getPromptAction().showToast({ message: this.settings.error });
    });
  }

  private userDocumentPreview(): string {
    const document = (this.app.config.userDocument || '').trim();
    return document.length > 0 ? document.replace(/\s+/g, ' ') : t('填写称呼、背景和回答偏好');
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
                image: providerLogo(preset.id), tintImage: monochromeProviderLogo(preset.id), icon: $r('sys.symbol.cloud'), iconWidth: 28,
                disabled: !this.canEdit(), onTap: () => this.choosePreset(preset.id) })
            }, (preset: ProviderInfo) => preset.id)
            RowDivider()
            NavRow({ title: t('添加自定义服务'), compId: 'add-custom-provider', icon: $r('sys.symbol.plus'), iconWidth: 28, accent: true,
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
              NavRow({ title: profile.name, compId: 'edit-provider-' + profile.id, icon: $r('sys.symbol.cloud'), iconWidth: 28,
                image: providerLogo(profile.presetId || ''), tintImage: monochromeProviderLogo(profile.presetId || ''),
                subtitle: t("{0} · {1} 个模型", [protocolName(profile.protocol), profile.models.length]),
                value: profile.enabled ? '' : t("已停用"), muted: !profile.enabled, disabled: !this.canEdit(),
                onTap: () => this.onEditProvider(profile.id, '') })
              RowDivider()
            }, (profile: ProviderProfile) => JSON.stringify(profile))
            NavRow({ title: t('添加模型服务'), compId: 'add-provider', icon: $r('sys.symbol.plus'), iconWidth: 28, accent: true,
              disabled: !this.canEdit(), onTap: () => { this.showPresets = true; } })
            RowDivider()
            NavRow({ title: t('模型分工与能力'), subtitle: t('自动选择模型、专用模型与能力配置'), compId: 'open-model-settings',
              icon: $r('sys.symbol.gearshape'), iconWidth: 28, disabled: !this.canEdit(), onTap: () => this.onModels() })
          }
        }
        SectionHeader({ title: t('长期记忆') })
        GroupCard() {
          Column() {
            SwitchRow({ title: t('自动提取长期记忆'), compId: 'auto-memory',
              isOn: this.assistantDraft.autoMemory, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveAssistantToggle('memory', value) })
            RowDivider()
            NavRow({ title: t('管理长期记忆'), subtitle: t('查看、编辑所有对话或当前对话的记忆'), compId: 'open-memory',
              icon: $r('sys.symbol.lightbulb'), disabled: !this.canEdit(), onTap: () => this.onTools('memory') })
          }
        }
        SectionHeader({ title: t("助手") })
        GroupCard() {
          Column() {
            NavRow({ title: t('用户文档（USER.md）'), subtitle: this.userDocumentPreview(), compId: 'open-user-document',
              icon: $r('sys.symbol.square_and_pencil'), disabled: !this.canEdit(), onTap: () => this.onUserDocument() })
            RowDivider()
            SwitchRow({ title: t("自动压缩历史"), compId: 'auto-compact', isOn: this.settings.autoCompact,
              subtitle: t("接近上下文预算时，用当前模型生成摘要，完整记录保留。"), disabled: !this.canEdit(),
              onChange: (value: boolean) => { this.saveToggle((v: boolean) => { this.settings.autoCompact = v; }, value); } })
            RowDivider()
            SwitchRow({ title: t('只读任务'), subtitle: t('阻止修改文件、调用远程工具和生成图片。'), compId: 'read-only',
              isOn: this.assistantDraft.readOnly, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveAssistantToggle('readOnly', value) })
            RowDivider()
            SwitchRow({ title: t('任务结束后保存结果'), subtitle: t('把成功的回答归档到工作区的“任务结果”目录。'), compId: 'save-summary',
              isOn: this.assistantDraft.saveSummary, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveAssistantToggle('summary', value) })
          }
        }
        SectionHeader({ title: t('工具与扩展') })
        GroupCard() {
          Column() {
            NavRow({ title: 'Skills', compId: 'open-skills', icon: $r('sys.symbol.wand_and_stars'),
              value: t('{0} 个已启用', [this.app.extensions.skills.filter((skill) => skill.enabled).length]),
              disabled: !this.canEdit(), onTap: () => this.onSkills() })
            RowDivider()
            NavRow({ title: t('提示词模板'), compId: 'open-templates', icon: $r('sys.symbol.doc_plaintext'),
              disabled: !this.canEdit(), onTap: () => this.onTools('templates') })
            RowDivider()
            NavRow({ title: t('MCP 服务'), compId: 'open-mcp', icon: $r('sys.symbol.connection'),
              disabled: !this.canEdit(), onTap: () => this.onTools('mcp') })
          }
        }
        SectionHeader({ title: t('数据与用量') })
        GroupCard() {
          Column() {
            NavRow({ title: t('Token 用量'), subtitle: t('查看用量概览、每日趋势和请求明细'), compId: 'open-usage',
              icon: $r('sys.symbol.clock'), onTap: () => this.onUsage() })
            RowDivider()
            NavRow({ title: t('备份与恢复'), compId: 'open-backup', icon: $r('sys.symbol.folder_badge_plus'),
              disabled: !this.canEdit(), onTap: () => this.onBackup() })
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
        SectionHeader({ title: t('关于') })
        GroupCard() {
          Column() {
            NavRow({ title: t('使用帮助'), compId: 'open-help', onTap: () => this.onSupport('help') })
            RowDivider()
            NavRow({ title: t('评分和评论'), compId: 'open-rating', onTap: () => this.onSupport('rating') })
            RowDivider()
            NavRow({ title: t('关于 Tinybot'), compId: 'open-about', onTap: () => this.onSupport('about') })
          }
        }
      }.padding({ left: Space.page, right: Space.page, bottom: Space.xl }).width('100%')
    }.height('100%').width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
    .bindSheet($$this.showPresets, this.presetsSheet(), { title: { title: t('添加模型服务') }, detents: [SheetSize.LARGE], dragBar: true,
      backgroundColor: $r('app.color.page_background') })
  }
}

@Component
export struct UserDocumentPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onSaved: () => void = () => {};

  build() {
    Column() {
      Column({ space: Space.md }) {
        Text(t('USER.md 会附加到所有对话的上下文，保存后从下一轮生效。系统提示词由应用维护，不可修改。清空文档即可停用个人偏好。'))
          .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
        TextArea({ text: this.settings.userDocument, placeholder: t('例如：\n# 关于我\n请称呼我为…\n\n# 回答偏好\n先给结论，再给必要的例子。') }).id('user-document')
          .attributeModifier(Styles.area).layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .enabled(!this.app.busy && this.app.saveError.length === 0)
          .onChange((value: string) => { this.settings.userDocument = value; })
        if (this.settings.error.length > 0) {
          Banner({ text: this.settings.error })
        }
      }.layoutWeight(1).padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.md })
      BottomBar() {
        Button(this.app.busy ? t("正在保存…") : t("保存")).id('save-settings').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.busy && this.app.saveError.length === 0)
          .onClick(async () => { if (await this.app.saveSettings()) { this.onSaved(); } })
      }
    }.width('100%').height('100%')
  }
}
