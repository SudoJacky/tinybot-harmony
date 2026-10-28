import { AppearanceStyle } from '../common/AppearanceStyle';
import { HuaweiAccount } from '../services/HuaweiAccount';
import { t } from '../model/I18n';
import { searchSettingsSummary } from '../model/SearchEditor';
import { languageName } from './LanguagePanel';
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
  @StorageProp('tinybot.developer.enabled') private developerEnabled: boolean = false;
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.language') private language: string = 'system';
  @Prop presetsOnly: boolean = false;
  @State private assistantDraft: AssistantOptions = defaultAssistantOptions();
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  @ObjectLink browser: BrowserSession;
  @ObjectLink account: HuaweiAccount;
  onAccount: () => void = () => {};
  onEditProvider: (id: string, preset: string) => void = () => {};
  onAddProvider: () => void = () => {};
  onSkills: () => void = () => {};
  onUserDocument: () => void = () => {};
  onUsage: () => void = () => {};
  onStorage: () => void = () => {};
  onModels: () => void = () => {};
  onSearch: () => void = () => {};
  onBackup: () => void = () => {};
  onAppearance: () => void = () => {};
  onLanguage: () => void = () => {};
  onSupport: (page: string) => void = () => {};
  onTools: (tab: string) => void = () => {};
  private pendingSave: Promise<void> = Promise.resolve();
  private toggleRevisions: Map<SettingsToggle, number> = new Map<SettingsToggle, number>();

  // A brief save leaves the page untouched; a reply, compaction or team run locks it with a notice.
  private blocked(): boolean { return this.app.busy && !this.app.saving; }
  // Editors need a mutable session; unsaved chat data must be resolved first.
  private canEdit(): boolean { return !this.blocked() && this.app.saveError.length === 0; }
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
    return document.replace(/\s+/g, ' ');
  }

  private choosePreset(id: string): void {
    this.onEditProvider('', id);
  }
  @Builder
  presetsPage() {
    Scroll() {
      Column() {
        GroupCard() {
          Column() {
            ForEach(this.app.providerPresets, (preset: ProviderInfo, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: preset.name, subtitle: protocolName(preset.protocol), compId: 'preset-' + preset.id,
                image: providerLogo(preset.id), tintImage: monochromeProviderLogo(preset.id), icon: $r('sys.symbol.cloud'),
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

  @Builder
  settingsPage() {
    Scroll() {
      Column() {
        this.statusBanners()
        SectionHeader({ title: t('账号') })
        GroupCard() {
          NavRow({ title: t('华为账号'), value: this.account.signedIn ? t('已登录') : t('未登录'),
            icon: $r('sys.symbol.person'), compId: 'open-huawei-account', onTap: this.onAccount })
        }
        SectionHeader({ title: t('模型与服务') })
        GroupCard() {
          Column() {
            ForEach(this.app.providerProfiles, (profile: ProviderProfile) => {
              NavRow({ title: profile.name, compId: 'edit-provider-' + profile.id, icon: $r('sys.symbol.cloud'),
                image: providerLogo(profile.presetId || ''), tintImage: monochromeProviderLogo(profile.presetId || ''),
                subtitle: t("{0} · {1} 个模型", [protocolName(profile.protocol), profile.models.length]),
                value: profile.enabled ? '' : t("已停用"), muted: !profile.enabled, disabled: !this.canEdit(),
                onTap: () => this.onEditProvider(profile.id, '') })
              RowDivider()
            }, (profile: ProviderProfile) => JSON.stringify(profile))
            NavRow({ title: t('添加模型服务'), compId: 'add-provider', icon: $r('sys.symbol.plus'), accent: true,
              disabled: !this.canEdit(), onTap: this.onAddProvider })
            RowDivider()
            NavRow({ title: t('模型分工与能力'), compId: 'open-model-settings',
              icon: $r('sys.symbol.gearshape'), disabled: !this.canEdit(), onTap: () => this.onModels() })
          }
        }
        SectionHeader({ title: t('助手偏好') })
        GroupCard() {
          Column() {
            NavRow({ title: t('称呼与回答偏好'), subtitle: this.userDocumentPreview(), compId: 'open-user-document',
              icon: $r('sys.symbol.square_and_pencil'), disabled: !this.canEdit(), onTap: () => this.onUserDocument() })
            RowDivider()
            NavRow({ title: t('提示词模板'), compId: 'open-templates', icon: $r('sys.symbol.doc_plaintext'),
              disabled: !this.canEdit(), onTap: () => this.onTools('templates') })
            RowDivider()
            SwitchRow({ title: t('自动保存任务结果'), icon: $r('sys.symbol.archivebox'), subtitle: t('把成功的回答归档到工作区的“任务结果”目录。'), compId: 'save-summary',
              isOn: this.assistantDraft.saveSummary, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('saveSummary', value) })
          }
        }
        SectionHeader({ title: t('记忆与上下文') })
        GroupCard() {
          Column() {
            SwitchRow({ title: t('自动提取长期记忆'), icon: $r('sys.symbol.wand_and_stars'), compId: 'auto-memory',
              subtitle: t('每 10 轮后台整理，会额外调用模型。'),
              isOn: this.assistantDraft.autoMemory, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('autoMemory', value) })
            RowDivider()
            NavRow({ title: t('管理长期记忆'), compId: 'open-memory',
              icon: $r('sys.symbol.lightbulb'), disabled: !this.canEdit(), onTap: () => this.onTools('memory') })
            RowDivider()
            SwitchRow({ title: t("自动压缩历史"), icon: $r('sys.symbol.rectangle_stack'), compId: 'auto-compact', isOn: this.settings.autoCompact,
              subtitle: t('接近上下文上限时生成摘要，完整记录保留。'), disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('autoCompact', value) })
          }
        }
        SectionHeader({ title: t('工具与权限') })
        GroupCard() {
          Column() {
            SwitchRow({ title: t('只读模式'), icon: $r('sys.symbol.lock'), subtitle: t('对所有对话生效，阻止修改文件和调用远程工具。'), compId: 'read-only',
              isOn: this.assistantDraft.readOnly, disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('readOnly', value) })
            RowDivider()
            SwitchRow({ title: t('允许网页读取与搜索'), icon: $r('sys.symbol.doc_text'), compId: 'web-enabled', isOn: this.settings.webEnabled,
              subtitle: t('不影响模型服务与浏览器权限。'), disabled: !this.canEdit(),
              onChange: (value: boolean) => this.saveToggle('webEnabled', value) })
            RowDivider()
            NavRow({ title: t('搜索服务'), icon: $r('sys.symbol.magnifyingglass'), subtitle: searchSettingsSummary(this.app.productivity.options?.search), compId: 'open-search-settings',
              disabled: !this.canEdit(), onTap: this.onSearch })
            RowDivider()
            SwitchRow({ title: t('应用内浏览器'), icon: $r('sys.symbol.link'), compId: 'browser-enabled', isOn: this.browser.policy === 'enabled',
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
            NavRow({ title: t('MCP 服务'), compId: 'open-mcp', icon: $r('sys.symbol.connection'),
              disabled: !this.canEdit(), onTap: () => this.onTools('mcp') })
          }
        }
        SectionHeader({ title: t('界面与语言') })
        GroupCard() {
          Column() {
            NavRow({ title: t('界面与外观'), icon: $r('sys.symbol.picture'),
              compId: 'open-appearance', onTap: () => this.onAppearance() })
            RowDivider()
            NavRow({ title: t('语言'), icon: $r('sys.symbol.textformat'), value: languageName(this.language),
              compId: 'open-language', disabled: !this.canEdit(), onTap: this.onLanguage })
          }
        }
        SectionHeader({ title: t('数据与用量') })
        GroupCard() {
          Column() {
            NavRow({ title: t('Token 用量'), compId: 'open-usage',
              icon: $r('sys.symbol.clock'), onTap: () => this.onUsage() })
            RowDivider()
            NavRow({ title: t('存储空间'), compId: 'open-storage', icon: $r('sys.symbol.rectangle_stack'),
              subtitle: t('查看分类占用并清理缓存'), disabled: !this.canEdit(), onTap: () => this.onStorage() })
            RowDivider()
            NavRow({ title: t('备份与恢复'), compId: 'open-backup', icon: $r('sys.symbol.folder_badge_plus'),
              disabled: !this.canEdit(), onTap: () => this.onBackup() })
          }
        }
        SectionHeader({ title: t('帮助与关于') })
        GroupCard() {
          Column() {
            NavRow({ title: t('使用帮助'), icon: $r('sys.symbol.questionmark_circle'), compId: 'open-help', onTap: () => this.onSupport('help') })
            RowDivider()
            NavRow({ title: t('评分和评论'), icon: $r('sys.symbol.star'), compId: 'open-rating', onTap: () => this.onSupport('rating') })
            RowDivider()
            NavRow({ title: t('关于 Tinybot'), icon: $r('sys.symbol.info_circle'), compId: 'open-about', onTap: () => this.onSupport('about') })
            if (this.developerEnabled) {
              RowDivider()
              NavRow({ title: t('开发者模式'), icon: $r('sys.symbol.wrench_and_screwdriver'), subtitle: t('性能统计、慢操作与诊断日志'), compId: 'open-developer', onTap: () => this.onSupport('developer') })
            }
          }
        }
      }.padding({ left: Space.page, right: Space.page, bottom: Space.xl }).width('100%')
    }.height('100%').width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
  }
  build() {
    if (this.presetsOnly) { this.presetsPage() }
    else { this.settingsPage() }
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
