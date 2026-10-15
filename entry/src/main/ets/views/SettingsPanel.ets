import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { AppLanguage } from '../model/I18n';
import { LanguagePreferences } from '../services/LanguagePreferences';
import { AgentMode, AGENT_MODES, agentModeName } from '../model/AgentMode';
import { OPTIONAL_TOOL_NAMES } from '../model/ToolGroups';
import { CustomToolsPanel } from './CustomToolsPanel';
import { BrowserSession } from '../services/BrowserSession';
import { ChatViewModel, SettingsViewModel } from '../viewmodel/ChatViewModel';
import { SettingsToggle } from '../services/SessionContracts';
import { ProviderInfo } from '../model/Provider';
import { ProviderProfile } from '../model/ProviderProfiles';
import { AssistantOptions, defaultAssistantOptions } from '../model/AssistantOptions';
import { Btn, Font, Space, Styles, protocolName } from '../common/Theme';
import { monochromeProviderLogo, providerLogo } from '../common/ProviderBrand';
import { Banner, BottomBar, GroupCard, NavRow, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

@Component
export struct SettingsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.language') private language: string = 'system';
  @State private languageError: string = '';
  @State private showLanguage: boolean = false;
  @State private showPresets: boolean = false;
  @State private showAgentMode: boolean = false;
  @State private showCustomTools: boolean = false;
  @State private assistantDraft: AssistantOptions = defaultAssistantOptions();
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  @ObjectLink browser: BrowserSession;
  onEditProvider: (id: string, preset: string) => void = () => {};
  onSkills: () => void = () => {};
  onUserDocument: () => void = () => {};
  onUsage: () => void = () => {};
  onModels: () => void = () => {};
  onSearch: () => void = () => {};
  onBackup: () => void = () => {};
  onAppearance: () => void = () => {};
  onSupport: (page: string) => void = () => {};
  onTools: (tab: string) => void = () => {};
  private pendingSave: Promise<void> = Promise.resolve();
  private toggleRevisions: Map<SettingsToggle, number> = new Map<SettingsToggle, number>();

  // A brief save leaves the page untouched; a reply, compaction or team run locks it with a notice.
  private blocked(): boolean { return this.app.busy && !this.app.saving; }
  // Editors need a mutable session; unsaved chat data must be resolved first.
  private canEdit(): boolean { return !this.blocked() && this.app.saveError.length === 0; }
  private canSelectMode(): boolean { return this.canEdit() && !this.app.active.archived; }
  private async selectMode(mode: AgentMode): Promise<void> {
    await this.pendingSave;
    if (this.canSelectMode() && await this.app.setAgentMode(mode)) { this.showAgentMode = false; }
  }

  @Builder
  agentModeSheet() {
    Column({ space: Space.md }) {
      GroupCard() {
        Column() {
          ForEach(AGENT_MODES, (mode: AgentMode, index: number) => {
            if (index > 0) { RowDivider() }
            NavRow({ title: agentModeName(mode), trailing: 'select', active: this.app.active.agentMode === mode,
              compId: 'settings-agent-mode-' + mode, disabled: !this.canSelectMode(), onTap: () => this.selectMode(mode) })
          }, (mode: AgentMode) => mode)
        }
      }
      Text(t('仅用于当前对话，选择会随下一条消息保存。')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
        .fontColor($r('app.color.text_secondary')).width('100%')
    }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
  }

  @Builder
  customToolsSheet() {
    CustomToolsPanel({ app: this.app, thread: this.app.active })
  }

  aboutToAppear(): void { this.resetAssistantDraft(); }

  private resetAssistantDraft(): void {
    this.assistantDraft = JSON.parse(JSON.stringify(this.app.productivity.options || defaultAssistantOptions())) as AssistantOptions;
  }

  private setToggleDraft(kind: SettingsToggle, value: boolean): void {
    if (kind === 'autoMemory') { this.assistantDraft.autoMemory = value; }
    else if (kind === 'readOnly') { this.assistantDraft.readOnly = value; }
    else if (kind === 'saveSummary') { this.assistantDraft.saveSummary = value; }
    else if (kind === 'autoCompact') { this.settings.autoCompact = value; }
    else if (kind === 'webEnabled') { this.settings.webEnabled = value; }
  }

  private savedToggleValue(kind: SettingsToggle): boolean {
    const options = this.app.productivity.options || defaultAssistantOptions();
    if (kind === 'autoMemory') { return options.autoMemory; }
    if (kind === 'readOnly') { return options.readOnly; }
    if (kind === 'saveSummary') { return options.saveSummary; }
    if (kind === 'autoCompact') { return this.app.config.autoCompact !== false; }
    return this.app.extensions.webEnabled;
  }

  // Respond immediately; serialize field changes without locking or resetting unrelated drafts.
  private saveToggle(kind: SettingsToggle, value: boolean): void {
    if (!this.canEdit()) { return; }
    this.setToggleDraft(kind, value);
    const revision = (this.toggleRevisions.get(kind) || 0) + 1;
    this.toggleRevisions.set(kind, revision);
    this.pendingSave = this.pendingSave.then(async () => {
      if (await this.app.setSettingsToggle(kind, value)) { return; }
      // An earlier failure cannot undo a newer click on the same switch.
      if (this.toggleRevisions.get(kind) === revision) { this.setToggleDraft(kind, this.savedToggleValue(kind)); }
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: this.settings.error });
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
      Column() {
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
        Text(t('选择服务后，地址和常用模型会自动填好。')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
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
              subtitle: t('按需保存长期事实，每 10 轮后台复盘；会额外调用模型。'),
              isOn: this.assistantDraft.autoMemory, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('autoMemory', value) })
            RowDivider()
            NavRow({ title: t('管理长期记忆'), subtitle: t('查看、编辑所有对话或当前对话的记忆'), compId: 'open-memory',
              icon: $r('sys.symbol.lightbulb'), disabled: !this.canEdit(), onTap: () => this.onTools('memory') })
          }
        }
        SectionHeader({ title: t("助手") })
        GroupCard() {
          Column() {
            NavRow({ title: t('Agent 模式'), value: agentModeName(this.app.active.agentMode), compId: 'settings-agent-mode',
              subtitle: t('仅用于当前对话，选择会随下一条消息保存。'), icon: $r('sys.symbol.gearshape'),
              disabled: !this.canSelectMode(), onTap: () => { this.showAgentMode = true; } })
              .bindSheet($$this.showAgentMode, this.agentModeSheet(), { title: { title: t('Agent 模式') }, detents: [SheetSize.FIT_CONTENT], dragBar: true,
                backgroundColor: $r('app.color.page_background') })
            RowDivider()
            if (this.app.active.agentMode === 'custom') {
              NavRow({ title: t('自定义工具'), compId: 'open-custom-tools', icon: $r('sys.symbol.wrench_and_screwdriver'),
                value: t('已开启 {0} / {1} 个可选工具', [OPTIONAL_TOOL_NAMES.length - this.app.active.disabledTools.length, OPTIONAL_TOOL_NAMES.length]),
                disabled: !this.canSelectMode(), onTap: () => { this.showCustomTools = true; } })
                .bindSheet($$this.showCustomTools, this.customToolsSheet(), { title: { title: t('自定义工具') }, detents: [SheetSize.LARGE], dragBar: true,
                  backgroundColor: $r('app.color.page_background') })
              RowDivider()
            }
            NavRow({ title: t('用户文档（USER.md）'), subtitle: this.userDocumentPreview(), compId: 'open-user-document',
              icon: $r('sys.symbol.square_and_pencil'), disabled: !this.canEdit(), onTap: () => this.onUserDocument() })
            RowDivider()
            SwitchRow({ title: t("自动压缩历史"), compId: 'auto-compact', isOn: this.settings.autoCompact,
              subtitle: t("接近上下文预算时，用当前模型生成摘要，完整记录保留。"), disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('autoCompact', value) })
            RowDivider()
            SwitchRow({ title: t('只读任务'), subtitle: t('阻止修改文件、调用远程工具和生成图片。'), compId: 'read-only',
              isOn: this.assistantDraft.readOnly, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('readOnly', value) })
            RowDivider()
            SwitchRow({ title: t('任务结束后保存结果'), subtitle: t('把成功的回答归档到工作区的“任务结果”目录。'), compId: 'save-summary',
              isOn: this.assistantDraft.saveSummary, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('saveSummary', value) })
          }
        }
        SectionHeader({ title: t('工具与扩展') })
        GroupCard() {
          Column() {
            SwitchRow({ title: t('应用内浏览器'), compId: 'browser-enabled', isOn: this.browser.policy === 'enabled',
              subtitle: this.browser.policy === 'unset' ? t('默认关闭，首次需要时询问。') : this.browser.policy === 'disabled' ? t('已关闭，助手不会再次请求启用。') : t('允许助手操作网页；你可以随时接管。'),
              disabled: this.browser.permissionSaving || !this.app.ready || this.app.saveError.length > 0,
              onChange: async (value: boolean) => { try { await this.browser.setEnabled(value); }
                catch (error) { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: (error as Error).message }); } } })
            if (this.browser.policy === 'unset') {
              Button(t('不再询问启用')).fontFamily(this.appearance.fontFamily).id('browser-disable-requests').attributeModifier(Btn.textSmall).enabled(!this.browser.permissionSaving)
                .onClick(async () => { try { await this.browser.setEnabled(false); }
                  catch (error) { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: (error as Error).message }); } })
            }
            RowDivider()
            NavRow({ title: 'Skills', compId: 'open-skills', icon: $r('sys.symbol.wand_and_stars'),
              value: t('{0} 个已启用', [this.app.extensions.skills.filter((skill) => skill.enabled).length]),
              disabled: !this.canEdit(), onTap: () => this.onSkills() })
            RowDivider()
            NavRow({ title: t('提示词模板'), compId: 'open-templates', icon: $r('sys.symbol.doc_plaintext'),
              disabled: !this.canEdit(), onTap: () => this.onTools('templates') })
            RowDivider()
            NavRow({ title: t('MCP 服务'), compId: 'open-mcp', icon: $r('sys.symbol.connection'),
              disabled: !this.canEdit(), onTap: () => this.onTools('mcp') })
            RowDivider()
            NavRow({ title: t('联网搜索'), subtitle: 'DeepSeek / Tavily', compId: 'open-search-settings',
              disabled: !this.canEdit(), onTap: this.onSearch })
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
          SwitchRow({ title: t('允许联网'), compId: 'web-enabled', isOn: this.settings.webEnabled,
            subtitle: t('允许网页读取和已配置的搜索；获取的内容会发送给当前模型。'), disabled: !this.canEdit(),
            onChange: (value: boolean) => this.saveToggle('webEnabled', value) })
        }
        SectionHeader({ title: t('偏好设置') })
        GroupCard() {
          Column() {
            NavRow({ title: t('界面与外观'), subtitle: t('主题色、字体、明暗模式与光感效果'),
              compId: 'open-appearance', onTap: () => this.onAppearance() })
            RowDivider()
            NavRow({ title: t('语言'), value: this.languageName(this.language),
              compId: 'open-language', disabled: !this.canEdit(), onTap: () => { this.showLanguage = true; } })
              .bindSheet($$this.showLanguage, this.languageSheet(), { title: { title: t('语言') }, height: SheetSize.FIT_CONTENT,
                dragBar: true, systemMaterial: this.appearance.surface })
          }
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
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onSaved: () => void = () => {};

  build() {
    Column() {
      Column({ space: Space.md }) {
        Text(t('USER.md 会附加到所有对话的上下文，保存后从下一轮生效。系统提示词由应用维护，不可修改。清空文档即可停用个人偏好。')).fontFamily(this.appearance.fontFamily)
          .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
        TextArea({ text: this.settings.userDocument, placeholder: t('例如：\n# 关于我\n请称呼我为…\n\n# 回答偏好\n先给结论，再给必要的例子。') }).fontFamily(this.appearance.fontFamily).id('user-document')
          .attributeModifier(Styles.area).layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .enabled(!this.app.busy && this.app.saveError.length === 0)
          .onChange((value: string) => { this.settings.userDocument = value; })
        if (this.settings.error.length > 0) {
          Banner({ text: this.settings.error })
        }
      }.layoutWeight(1).padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.md })
      BottomBar() {
        Button(this.app.busy ? t("正在保存…") : t("保存")).fontFamily(this.appearance.fontFamily).id('save-settings').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.busy && this.app.saveError.length === 0)
          .onClick(async () => { if (await this.app.saveSettings()) { this.onSaved(); } })
      }
    }.width('100%').height('100%')
  }
}
