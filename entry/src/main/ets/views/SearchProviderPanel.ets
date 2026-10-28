import { AppearanceStyle } from '../common/AppearanceStyle';
import { menuMaterialAttribute, systemMaterialAttribute } from '../common/MaterialAttributes';
import { Btn, Space } from '../common/Theme';
import { Banner, BottomBar, GroupCard, RowDivider } from '../common/Widgets';
import { t } from '../model/I18n';
import { ProviderProfile } from '../model/ProviderProfiles';
import { deepSeekSearchProfiles, isSupportedSearchProvider } from '../model/WebSearch';
import { SearchEditorDraft, SearchProviderRoute, searchEditorDraft, tavilyKeyReady } from '../model/SearchEditor';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@Component
export struct SearchProviderPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  request: SearchProviderRoute = { provider: 'deepseek', draft: searchEditorDraft() };
  @State private draft: SearchEditorDraft = searchEditorDraft();
  onDone: (draft?: SearchEditorDraft) => void = () => {};

  aboutToAppear(): void { this.draft = JSON.parse(JSON.stringify(this.request.draft)) as SearchEditorDraft; }
  aboutToDisappear(): void { this.draft.apiKey = ''; this.request.draft.apiKey = ''; }
  private candidates(): ProviderProfile[] { return deepSeekSearchProfiles(this.app.providerProfiles); }
  private locked(): boolean { return this.app.sharedBusy || !!this.app.saveError; }
  private done(): void {
    if (this.locked()) { return; }
    this.onDone(isSupportedSearchProvider(this.request.provider) ? JSON.parse(JSON.stringify(this.draft)) as SearchEditorDraft : undefined);
  }
  @Builder
  deepseek() {
    Text(t('DeepSeek 搜索按请求次数计费，不再产生模型用量。')).fontFamily(this.appearance.fontFamily)
      .fontSize(14).fontColor($r('app.color.text_secondary'))
    if (this.candidates().length > 0) {
      Text(t('DeepSeek 服务')).fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary'))
      Select(this.candidates().map((item: ProviderProfile): SelectOption => ({ value: item.name })))
        .selected(this.candidates().findIndex((item) => item.id === this.draft.modelProviderId || (!this.draft.modelProviderId && this.candidates().length === 1)))
        .value(this.candidates().find((item) => item.id === this.draft.modelProviderId)?.name ||
          (!this.draft.modelProviderId && this.candidates().length === 1 ? this.candidates()[0].name : t('请选择用于联网搜索的 DeepSeek 服务。')))
        .enabled(!this.locked()).id('search-credential-source')
        .backgroundColor(this.appearance.controlBackground).fontColor($r('sys.color.font_primary'))
        .attributeModifier(systemMaterialAttribute<SelectAttribute>(this.appearance.control))
        .attributeModifier(menuMaterialAttribute(this.appearance.surface))
        .onSelect((index: number) => { this.draft.modelProviderId = this.candidates()[index].id; })
      Text(t('复用所选官方模型服务的密钥，无需重复填写。')).fontFamily(this.appearance.fontFamily)
        .id('search-provider-key-ready').fontSize(13).fontColor($r('app.color.text_secondary'))
    } else {
      Banner({ text: t('请先在设置中添加并启用 DeepSeek 官方模型服务，配置 API Key。'), danger: false, compId: 'search-provider-key-missing' })
    }
  }
  @Builder
  tavily() {
    Text(t('搜索接口基础地址')).fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary'))
    TextInput({ text: this.draft.baseUrl, placeholder: 'https://api.tavily.com' }).fontFamily(this.appearance.fontFamily)
      .id('search-base-url').enabled(!this.locked()).onChange((value: string) => { this.draft.baseUrl = value; })
    Text('API Key').fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary'))
    TextInput({ text: this.draft.apiKey, placeholder: tavilyKeyReady(this.draft) ? t('留空保留已保存的搜索密钥') : 'API Key' })
      .fontFamily(this.appearance.fontFamily).type(InputType.Password).id('search-api-key').enabled(!this.locked())
      .onChange((value: string) => { this.draft.apiKey = value; if (value.trim()) { this.draft.clearKey = false; } })
    if (this.draft.savedKey || this.draft.apiKey || this.draft.clearKey) {
      Button(this.draft.clearKey ? t('撤销清除密钥') : t('清除已保存的密钥')).fontFamily(this.appearance.fontFamily)
        .attributeModifier(Btn.textSmall).id('search-clear-key').enabled(!this.locked())
        .onClick(() => { this.draft.clearKey = !this.draft.clearKey; this.draft.apiKey = ''; })
    }
    if (this.draft.clearKey) {
      Banner({ text: t('密钥将在列表页保存后清除。'), danger: false, compId: 'search-key-removal-pending' })
    } else if (this.draft.savedKey && this.draft.baseUrl.trim().replace(/\/+$/, '') !== this.draft.savedBaseUrl && !this.draft.apiKey.trim()) {
      Banner({ text: t('更换搜索地址后需要重新填写密钥。'), danger: false, compId: 'search-key-endpoint-changed' })
    }
    Text(t('切换提供方会保留 Tavily 地址和密钥；更换地址或清除密钥在保存后生效。'))
      .fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
  }
  @Builder
  statusRow(title: string, value: string, compId: string) {
    Row({ space: Space.md }) {
      Text(title).fontFamily(this.appearance.fontFamily).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
      Text(value).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
    }.width('100%').constraintSize({ minHeight: 56 }).padding(Space.md).id(compId)
  }
  @Builder
  bing() {
    GroupCard() {
      Column() {
        this.statusRow(t('允许网页读取与搜索'), this.app.extensions.webEnabled ? t('已启用') : t('已停用'), 'search-browser-web-status')
        RowDivider()
        this.statusRow(t('应用内浏览器'), this.app.extensions.browserPolicy === 'enabled' ? t('已启用') :
          this.app.extensions.browserPolicy === 'disabled' ? t('已停用') : t('首次使用时询问'), 'search-browser-permission-status')
      }
    }
    Text(t('无需 API Key，通过应用内浏览器访问必应。需要允许浏览器使用；遇到验证时，请完成验证后交还控制。'))
      .fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_secondary')).id('search-browser-description')
    Text(t('关闭“允许网页读取与搜索”或禁用应用内浏览器都会停用内置搜索。'))
      .fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
  }
  build() {
    Column() {
      Scroll() {
        Column({ space: Space.md }) {
          if (this.request.provider === 'deepseek') { this.deepseek() }
          else if (this.request.provider === 'tavily') { this.tavily() }
          else if (this.request.provider === 'bing-browser') { this.bing() }
          else {
            Banner({ text: t('配置已保留，请选择受支持的提供方或升级应用。'), danger: false, compId: 'search-provider-unsupported' })
          }
          if (isSupportedSearchProvider(this.request.provider)) {
            Text(t('搜索词会发送给所选服务。')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
          }
          if (this.request.provider === 'deepseek' || this.request.provider === 'tavily') {
            Text(t('密钥保存在系统安全存储，不随备份导出。关闭“允许网页读取与搜索”也会停用搜索。'))
              .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
            Text(t('完成后返回列表，点击“保存”才会生效。')).fontFamily(this.appearance.fontFamily)
              .fontSize(13).fontColor($r('app.color.text_secondary')).id('search-provider-draft-notice')
          }
        }.width('100%').padding(Space.page).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top)
      BottomBar() {
        Button(t('完成')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.primary).width('100%')
          .id('search-provider-done').enabled(!this.locked()).onClick(() => this.done())
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
