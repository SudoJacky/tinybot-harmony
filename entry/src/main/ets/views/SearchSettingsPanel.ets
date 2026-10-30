import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { isSupportedSearchProvider } from '../model/WebSearch';
import { SearchEditorDraft, SearchProviderRoute, searchEditorDraft, searchProviderName, searchProviderStatus, searchSaveDraft } from '../model/SearchEditor';
import { Btn, Space } from '../common/Theme';
import { Banner, BottomBar, GroupCard, NavRow, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

@Component
export struct SearchSettingsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @State private draft: SearchEditorDraft = searchEditorDraft();
  @State private saved: string = '';
  @State private saving: boolean = false;
  @State private error: string = '';
  private initialized: boolean = false;
  onEdit: (request: SearchProviderRoute, onReturn: (draft?: SearchEditorDraft) => void) => void = () => {};

  aboutToAppear(): void {
    if (!this.initialized) { this.reset(); this.initialized = true; }
  }
  private reset(): void {
    this.draft = searchEditorDraft(this.app.productivity.options?.search);
    this.saved = JSON.stringify(this.draft);
  }
  private locked(): boolean { return this.saving || this.app.sharedBusy || !!this.app.saveError; }
  private dirty(): boolean { return JSON.stringify(this.draft) !== this.saved; }
  private providers(): string[] {
    const providers = ['deepseek', 'tavily', 'searxng', 'bing-browser'];
    const saved = this.app.productivity.options?.search?.provider;
    if (saved && !isSupportedSearchProvider(saved)) { providers.push(saved); }
    return providers;
  }
  private select(provider: string): void {
    if (this.locked()) { return; }
    this.draft.provider = provider; this.error = '';
  }
  private edit(provider: string): void {
    if (this.locked()) { return; }
    const request: SearchProviderRoute = { provider: provider, draft: JSON.parse(JSON.stringify(this.draft)) as SearchEditorDraft };
    this.onEdit(request, (result?: SearchEditorDraft) => {
      if (!result) { return; }
      // Opening details never selects a provider, and returning does not reset other edits.
      if (provider === 'deepseek') { this.draft.modelProviderId = result.modelProviderId; }
      else if (provider === 'tavily') {
        this.draft.baseUrl = result.baseUrl; this.draft.apiKey = result.apiKey; this.draft.clearKey = result.clearKey;
      }
      else if (provider === 'searxng') { this.draft.searxngBaseUrl = result.searxngBaseUrl; }
      this.error = '';
    });
  }
  private async save(): Promise<void> {
    if (this.locked() || !this.dirty() || !isSupportedSearchProvider(this.draft.provider)) { return; }
    this.saving = true; this.error = '';
    try {
      const ok = await this.app.saveSearch(searchSaveDraft(this.draft));
      this.error = this.app.error;
      if (ok) {
        this.reset();
        this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('搜索设置已保存') });
      }
    } finally { this.saving = false; }
  }
  build() {
    Column() {
      Scroll() {
        Column() {
          GroupCard() {
            Column() {
              SwitchRow({ title: t('启用联网搜索'), isOn: this.draft.enabled,
                disabled: this.locked() || !isSupportedSearchProvider(this.draft.provider), compId: 'search-enabled',
                onChange: (enabled: boolean) => { this.draft.enabled = enabled; } })
              if (!this.app.extensions.webEnabled) {
                Banner({ text: t('“允许网页读取与搜索”已关闭，启用后才能使用搜索。'), danger: false,
                  icon: $r('sys.symbol.exclamationmark_circle'), compId: 'search-web-disabled' }).padding({ left: Space.md, right: Space.md, bottom: Space.sm })
              }
            }
          }
          SectionHeader({ title: t('服务提供方') })
          GroupCard() {
            Column() {
              ForEach(this.providers(), (provider: string, index: number) => {
                if (index > 0) { RowDivider() }
                NavRow({ title: searchProviderName(provider),
                  subtitle: searchProviderStatus(provider, this.draft, this.app.providerProfiles, this.app.extensions.browserPolicy || 'unset'),
                  trailing: 'select', active: this.draft.provider === provider, disabled: this.locked(),
                  compId: 'search-provider-' + (isSupportedSearchProvider(provider) ? provider : 'unknown'),
                  actionLabel: isSupportedSearchProvider(provider) && provider !== 'bing-browser' ? t('配置') : t('详情'),
                  actionId: 'search-configure-' + (isSupportedSearchProvider(provider) ? provider : 'unknown'),
                  onTap: () => this.select(provider), onAction: () => this.edit(provider) })
              }, (provider: string) => provider)
            }
          }
        }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.md })
      }.width('100%').layoutWeight(1).align(Alignment.Top)
      BottomBar() {
        Column({ space: Space.sm }) {
          if (this.error || this.app.saveError) { Banner({ text: this.error || this.app.saveError, compId: 'search-save-error' }) }
          if (this.dirty()) {
            Text(t('有未保存的更改')).fontFamily(this.appearance.fontFamily).fontSize(13)
              .fontColor($r('app.color.text_secondary')).id('search-unsaved-changes')
          }
          Button(this.saving ? t('正在保存…') : t('保存')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.primary).width('100%')
            .enabled(!this.locked() && this.dirty() && isSupportedSearchProvider(this.draft.provider))
            .id('save-search-settings').onClick(() => this.save())
        }.width('100%')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
