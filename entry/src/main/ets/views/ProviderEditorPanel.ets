import { materialMenuContent } from '../common/MaterialMenu';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { FrameCallback } from '@kit.ArkUI';
import { Diagnostics } from '../model/Diagnostics';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { discoverModels } from '../services/ModelDiscovery';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';
import { Btn, Motion, Radius, Space, Styles, protocolName } from '../common/Theme';
import { Banner, BottomBar, GroupCard, IconButton, NavRow, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

class ProviderFocusFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(): void { this.action(); }
}

@Component
export struct ProviderEditorPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink editor: ProviderEditorViewModel;
  onSaved: () => void = () => {};
  @Prop page: string = 'service';
  @Prop @Watch('focusAvailabilityChanged') active: boolean = true;
  @StorageProp('tinybot.foreground') @Watch('focusAvailabilityChanged') private foreground: boolean = true;
  @Prop foundModels: string[] = [];
  @Prop initialModelError: string = '';
  onModels: (error: string) => void = () => {};
  onDiscovered: (models: string[]) => void = () => {};
  @State private discovering: boolean = false;
  @State @Watch('advancedChanged') private advanced: boolean = false;
  @State private replacingKey: boolean = false;
  @State private attempted: boolean = false;
  @State private modelError: string = '';
  @State private selectedModels: string[] = [];
  @State private modelQuery: string = '';
  private alive: boolean = true;
  private focusRequest: number = 0;
  private scroller: Scroller = new Scroller();
  private protocols: string[] = ['chat-completions', 'responses', 'anthropic-messages', 'gemini'];
  private protocolLabels: string[] = ['Chat Completions', 'Responses', 'Messages', 'Gemini'];
  private protocolLogos: Resource[] = [$r('app.media.logo_openai'), $r('app.media.logo_openai'), $r('app.media.logo_anthropic'), $r('app.media.logo_google')];

  aboutToAppear(): void { this.alive = true; this.modelError = this.initialModelError; }
  aboutToDisappear(): void { this.alive = false; this.focusRequest++; if (this.page === 'service') { this.editor.apiKey = ''; } }
  private focusAvailabilityChanged(): void { if (!this.active || !this.foreground) { this.focusRequest++; } }
  private advancedChanged(): void { if (!this.advanced) { this.focusRequest++; } }
  private focusField(field: string): void {
    const request = ++this.focusRequest;
    this.getUIContext().postFrameCallback(new ProviderFocusFrame(() => {
      if (request !== this.focusRequest || !this.alive || !this.active || !this.foreground || this.page !== 'service' || this.locked()) { return; }
      if (field === 'context' && !this.advanced || field === 'key' &&
        (this.editor.noApiKey || this.editor.canKeepKey && !this.replacingKey)) { return; }
      this.scroller.scrollEdge(field === 'context' ? Edge.Bottom : Edge.Top);
      Diagnostics.log('debug', 'focus', 'provider_requested', { request: request });
      this.getUIContext().getFocusController().requestFocus(field === 'context' ? 'context-window' : 'provider-' + field);
    }));
  }
  private locked(): boolean { return this.app.sharedBusy || this.discovering; }
  private async openApiKeyPage(): Promise<void> {
    const url = this.editor.apiKeyUrl;
    if (!url || this.locked()) { return; }
    try {
      await (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .startAbility({ action: 'ohos.want.action.viewData', uri: url });
    } catch (_) {
      if (this.alive) { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('无法打开系统浏览器。') }); }
    }
  }
  private async discover(): Promise<void> {
    if (this.locked()) { return; }
    this.attempted = true;
    if (this.editor.fieldError('url') || this.editor.fieldError('key')) { this.scroller.scrollEdge(Edge.Top); return; }
    const draft = this.editor.snapshot();
    this.discovering = true; this.editor.error = '';
    try {
      const models = await discoverModels(draft, this.app.providerProfiles);
      if (!this.alive) { return; }
      this.getUIContext().getFocusController().clearFocus(); this.onDiscovered(models);
    } catch (error) { if (this.alive) { this.editor.error = (error as Error).message; } }
    finally { if (this.alive) { this.discovering = false; } }
  }
  private async save(): Promise<void> {
    if (this.locked()) { return; }
    if (this.editor.modelInput.trim()) { this.addManual(); if (this.modelError) { this.onModels(this.modelError); return; } }
    this.attempted = true;
    const invalid = ['name', 'url', 'key', 'models', 'context'].find((field: string) => this.editor.fieldError(field).length > 0);
    if (invalid) {
      if (invalid === 'context') { this.advanced = true; }
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('请检查标出的设置项。') });
      if (invalid === 'models') { this.onModels(this.editor.fieldError('models')); return; }
      this.focusField(invalid);
      return;
    }
    this.getUIContext().getFocusController().clearFocus();
    if (await this.app.saveProvider()) { this.onSaved(); }
  }
  private addManual(): void {
    try { this.editor.addModels(this.editor.modelInput); this.editor.modelInput = ''; this.modelError = ''; }
    catch (error) { this.modelError = (error as Error).message; }
  }
  private toggleFound(id: string, selected: boolean): void {
    this.selectedModels = selected ? Array.from(new Set(this.selectedModels.concat([id]))) : this.selectedModels.filter((item) => item !== id);
  }
  private matches(): string[] { return this.foundModels.filter((id) => id.toLowerCase().includes(this.modelQuery.trim().toLowerCase())); }

  @Builder
  label(text: string) {
    Text(text).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').margin({ bottom: 6 })
  }
  @Builder
  fieldError(field: string) {
    if (this.attempted && this.editor.fieldError(field)) {
      Text(this.editor.fieldError(field)).fontFamily(this.appearance.fontFamily).id('provider-field-error-' + field).fontSize(12).lineHeight(18)
        .fontColor($r('app.color.danger')).width('100%').margin({ top: 6 })
    }
  }
  private protocolHint(protocol: string): string {
    return protocol === 'chat-completions' ? t('兼容大多数 OpenAI 格式的服务') :
      protocol === 'responses' ? t('OpenAI 新一代接口') : protocol === 'gemini' ? t('Google Gemini 原生接口') : t('Claude 模型使用的接口');
  }
  // Two columns keep all four protocol names readable on phone screens.
  @Builder
  protocolPicker() {
    Column({ space: Space.sm }) {
      Grid() {
        ForEach(this.protocols, (protocol: string, index: number) => {
          GridItem() {
            Column({ space: 6 }) {
              Image(this.protocolLogos[index]).width(24).height(24).objectFit(ImageFit.Contain)
                .fillColor(this.editor.protocol === protocol ? this.appearance.accent : $r('app.color.text_secondary'))
              Text(this.protocolLabels[index]).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(17).maxLines(2).textAlign(TextAlign.Center)
                .fontWeight(this.editor.protocol === protocol ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.editor.protocol === protocol ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
            }
            .id('provider-protocol-' + protocol).width('100%').height('100%')
            .justifyContent(FlexAlign.Center).padding({ left: 6, right: 6, top: 10, bottom: 10 })
            .borderRadius(Radius.md)
            .backgroundColor(this.editor.protocol === protocol ? this.appearance.accentTint : $r('app.color.surface_variant'))
            .border({ width: 1.5, color: this.editor.protocol === protocol ? this.appearance.accent : Color.Transparent })
            .animation({ duration: Motion.fast, curve: Motion.standard })
            .clickEffect(Motion.press)
            .accessibilityGroup(true)
            .accessibilityText(protocolName(protocol) + (this.editor.protocol === protocol ? t("，已选中") : ''))
            .onClick(() => { this.editor.changeProtocol(protocol); })
          }
        }, (protocol: string) => protocol)
      }.width('100%').height(164).columnsTemplate('1fr 1fr').rowsTemplate('1fr 1fr').columnsGap(Space.sm).rowsGap(Space.sm)
      Text(protocolName(this.editor.protocol) + ' · ' + this.protocolHint(this.editor.protocol)).fontFamily(this.appearance.fontFamily)
        .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
    }.width('100%')
  }
  private confirmDelete(): void {
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('删除模型服务？'),
      message: t('删除这份服务配置及其密钥，保留完整对话。使用它的会话需要重新选择模型。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('删除'), fontColor: $r('app.color.danger'), action: async () => {
        if (await this.app.deleteProvider(this.editor.id)) { this.onSaved(); }
      } } });
  }

  @Builder
  serviceActions() {
    Menu() {
      MenuItem(() => materialMenuContent.bind(this)({ label: t('删除此服务'), icon: $r('sys.symbol.trash'), danger: true })).id('delete-provider-' + this.editor.id)
        .enabled(!this.locked()).onClick(() => this.confirmDelete())
    }
  }

  @Builder
  modelRow(id: string) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(14).fontColor([this.appearance.accent])
      Text(id).fontFamily(this.appearance.fontFamily).fontSize(14).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1).fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice)
      IconButton({ icon: $r('sys.symbol.xmark'), label: t('移除模型 {0}', [id]), compId: 'remove-model-' + id,
        iconSize: 12, disabled: this.locked(), onTap: () => this.editor.removeModel(id) })
    }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 16, right: 4 })
  }
  @Builder
  modelsPage() {
    Column({ space: Space.md }) {
      Column({ space: 8 }) {
        Text(t('添加模型 ID')).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
        TextArea({ text: this.editor.modelInput, placeholder: t('粘贴模型 ID，支持换行或逗号分隔') }).fontFamily(this.appearance.fontFamily).id('provider-models')
          .attributeModifier(Styles.area).constraintSize({ minHeight: 60, maxHeight: 104 }).maxLength(10000)
          .onChange((value: string) => { this.editor.modelInput = value; this.modelError = ''; })
        Button(t('添加到列表')).fontFamily(this.appearance.fontFamily).id('add-manual-models').attributeModifier(Btn.tonal).width('100%')
          .enabled(this.editor.modelInput.trim().length > 0).onClick(() => this.addManual())
        if (this.modelError) { Banner({ text: this.modelError }) }
        this.fieldError('models')
      }.padding({ left: Space.page, right: Space.page })
      List() {
        ForEach(this.editor.modelList, (id: string) => { ListItem() { this.modelRow(id) } }, (id: string) => id)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      BottomBar() {
        Button(t('完成 · {0} 个模型', [this.editor.modelList.length])).fontFamily(this.appearance.fontFamily).id('finish-models').attributeModifier(Btn.primary).width('100%')
          .onClick(() => {
            if (this.editor.modelInput.trim()) { this.addManual(); if (this.modelError) { return; } }
            this.getUIContext().getFocusController().clearFocus(); this.onSaved();
          })
      }
    }.height('100%').width('100%').padding({ top: 8, bottom: 24 })
  }
  @Builder
  discoveryPage() {
    Column({ space: Space.md }) {
      Search({ value: this.modelQuery, placeholder: t('搜索模型 ID') }).textFont({ family: this.appearance.fontFamily })
        .placeholderFont({ family: this.appearance.fontFamily }).id('discovered-model-search').height(44)
        .margin({ left: Space.page, right: Space.page }).onChange((value: string) => { this.modelQuery = value; })
      if (this.matches().length === 0) { Text(t('没有匹配的模型')).fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary')).padding(16) }
      List() {
        ForEach(this.matches(), (id: string) => {
          ListItem() {
            Row({ space: 8 }) {
              Checkbox({ name: id }).select(this.editor.modelList.includes(id) || this.selectedModels.includes(id))
                .enabled(!this.editor.modelList.includes(id)).selectedColor(this.appearance.accent)
                .onChange((value: boolean) => this.toggleFound(id, value)).accessibilityText(id)
              Text(id).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.editor.modelList.includes(id)) { Text(t('已添加')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')) }
            }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 12, right: 16 })
            .onClick(() => { if (!this.editor.modelList.includes(id)) { this.toggleFound(id, !this.selectedModels.includes(id)); } })
          }
        }, (id: string) => id)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      BottomBar() {
        Column({ space: 8 }) {
          if (this.modelError) { Banner({ text: this.modelError }) }
          Button(t('添加所选模型（{0}）', [this.selectedModels.length])).fontFamily(this.appearance.fontFamily).id('add-discovered-models')
            .attributeModifier(Btn.primary).width('100%').enabled(this.selectedModels.length > 0)
            .onClick(() => {
              try { this.editor.addModels(this.selectedModels.join('\n')); this.onSaved(); }
              catch (error) { this.modelError = (error as Error).message; }
            })
        }
      }
    }.height('100%').width('100%').padding({ top: 8, bottom: 24 })
  }

  @Builder
  servicePage() {
    Column() {
      if (this.editor.id.length > 0) {
        Row() {
          Blank()
          Button(t('更多操作')).fontFamily(this.appearance.fontFamily).id('provider-more-actions').attributeModifier(Btn.text).height(44)
            .enabled(!this.locked()).bindMenu(this.serviceActions, {
              systemMaterial: this.appearance.menu, mask: false })
        }.width('100%').padding({ left: Space.page, right: Space.page })
      }
      Scroll(this.scroller) {
        Column() {
          Column() {
            GroupCard() {
              SwitchRow({ title: t('启用此服务'), compId: 'provider-enabled', isOn: this.editor.enabled,
                onChange: (value: boolean) => { this.editor.enabled = value; } })
            }
          }.margin({ top: Space.sm })
          SectionHeader({ title: t('连接') })
          GroupCard() {
            Column({ space: 12 }) {
              Column() {
                this.label(t('服务名称'))
                TextInput({ text: this.editor.name, placeholder: t('例如：我的 DeepSeek、公司代理') }).fontFamily(this.appearance.fontFamily).id('provider-name')
                  .attributeModifier(Styles.input).maxLength(80).enterKeyType(EnterKeyType.Next)
                  .onSubmit(() => this.focusField('url'))
                  .onChange((value: string) => { this.editor.name = value; })
                this.fieldError('name')
              }
              Column() {
                this.label(t('服务地址'))
                TextInput({ text: this.editor.baseUrl, placeholder: 'https://api.example.com/v1' }).fontFamily(this.appearance.fontFamily).id('provider-url')
                  .attributeModifier(Styles.input).type(InputType.URL).maxLength(1024)
                  .onChange((value: string) => { this.editor.baseUrl = value; })
                this.fieldError('url')
                if (this.editor.baseUrl.startsWith('http://')) {
                  Text(t('HTTP 连接未加密，仅适用于可信网络中的本地模型。')).fontFamily(this.appearance.fontFamily).fontSize(12).width('100%')
                    .fontColor($r('app.color.warning')).margin({ top: 6 })
                }
              }
            }.padding(12)
          }
          SectionHeader({ title: 'API Key' })
          GroupCard() {
            Column() {
              SwitchRow({ title: t('无需 API Key'), subtitle: t('适用于本地模型或内网代理'), compId: 'provider-no-key',
                isOn: this.editor.noApiKey, onChange: (value: boolean) => { this.editor.noApiKey = value; } })
              if (!this.editor.noApiKey) {
                RowDivider()
                if (this.editor.canKeepKey && !this.replacingKey) {
                  Row({ space: 8 }) {
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.appearance.accent])
                    Text(t('密钥已保存')).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
                    Button(t('更换')).fontFamily(this.appearance.fontFamily).id('replace-provider-key').attributeModifier(Btn.text).height(44).enabled(!this.locked())
                      .onClick(() => { this.replacingKey = true; })
                  }.padding({ left: 16, right: 4 }).width('100%').constraintSize({ minHeight: 56 })
                } else {
                  Column() {
                    TextInput({ text: this.editor.apiKey, placeholder: this.editor.canKeepKey ? t('留空保留原密钥') : t('填写 API Key') }).fontFamily(this.appearance.fontFamily)
                      .id('provider-key').attributeModifier(Styles.input).type(InputType.Password).showPasswordIcon(true)
                      .copyOption(CopyOptions.None).maxLength(512).onChange((value: string) => { this.editor.apiKey = value; })
                    this.fieldError('key')
                    if (this.editor.hasSavedKey && !this.editor.canKeepKey && !this.attempted) {
                      Text(t('服务基础地址已改变，请重新填写密钥。')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 6 })
                    }
                  }.padding(12)
                }
              }
            }
          }
          if (this.editor.apiKeyUrl) {
            Button() {
              Row({ space: 6 }) {
                Text(t('获取 API Key')).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor(this.appearance.accent)
                SymbolGlyph($r('sys.symbol.arrow_up_right')).fontSize(12).fontColor([this.appearance.accent])
              }
            }.fontFamily(this.appearance.fontFamily).id('get-provider-api-key').attributeModifier(Btn.text).height(44)
              .accessibilityText(t('获取 API Key，在浏览器中打开'))
              .enabled(!this.locked()).onClick(() => this.openApiKeyPage())
          }
          SectionHeader({ title: t('模型'), caption: t('已添加 {0} 个模型', [this.editor.modelList.length]) })
          GroupCard() {
            Column() {
              ForEach(this.editor.modelList.slice(0, 3), (id: string) => { this.modelRow(id); RowDivider() }, (id: string) => id)
              if (this.editor.modelList.length > 3) {
                NavRow({ title: t('查看全部 {0} 个模型', [this.editor.modelList.length]), compId: 'view-all-models',
                  disabled: this.locked(), onTap: () => this.onModels('') })
                RowDivider()
              }
              if (this.editor.modelList.length === 0) {
                Text(t('添加至少一个模型，即可开始对话。')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).padding(16).width('100%')
              }
              Row({ space: 8 }) {
                Button(this.discovering ? t('正在发现模型…') : t('获取模型')).fontFamily(this.appearance.fontFamily).id('discover-models').attributeModifier(Btn.tonal).layoutWeight(1)
                  .enabled(!this.locked()).onClick(() => this.discover())
                Button(t('手动添加')).fontFamily(this.appearance.fontFamily).id('manage-provider-models')
                  .attributeModifier(Btn.text).height(44).layoutWeight(1).enabled(!this.locked())
                  .onClick(() => this.onModels(''))
              }.padding(12).width('100%')
            }
          }
          this.fieldError('models')
          Column() {
            GroupCard() {
              Column() {
                NavRow({ title: t('高级设置'), subtitle: protocolName(this.editor.protocol) + ' · ' + (this.editor.contextWindow ? this.editor.contextWindow + ' tokens' : t('按模型自动设置')),
                  trailing: 'expand', active: this.advanced, compId: 'provider-advanced', disabled: this.locked(),
                  onTap: () => { this.advanced = !this.advanced; } })
                if (this.advanced) {
                  RowDivider()
                  Column({ space: 12 }) {
                    Column() {
                      this.label(t('协议'))
                      this.protocolPicker()
                    }
                    Column() {
                      this.label(t('上下文窗口（Token）'))
                      TextInput({ text: this.editor.contextWindow, placeholder: t('留空使用模型默认值') }).fontFamily(this.appearance.fontFamily).id('context-window').attributeModifier(Styles.input)
                        .type(InputType.Number).maxLength(7).onChange((value: string) => { this.editor.contextWindow = value; })
                      this.fieldError('context')
                      Text(t('单模型设置优先于此处。')).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(18)
                        .fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 6 })
                    }
                  }.padding(12)
                }
              }
            }
          }.margin({ top: 16 })
        }.padding({ left: Space.page, right: Space.page, bottom: Space.xl }).width('100%').enabled(!this.locked())
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto).align(Alignment.Top)
      BottomBar() {
        Column({ space: 8 }) {
          if (this.editor.error) { Banner({ text: this.editor.error, compId: 'provider-error' }) }
          Button(this.app.saving ? t('正在保存…') : this.editor.id ? t('保存更改') : t('保存服务')).fontFamily(this.appearance.fontFamily).id('save-provider')
            .attributeModifier(Btn.primary).width('100%').enabled(!this.locked()).onClick(() => this.save())
        }
      }
    }.width('100%').height('100%')
  }
  build() {
    if (this.page === 'models') { this.modelsPage() }
    else if (this.page === 'discovery') { this.discoveryPage() }
    else { this.servicePage() }
  }
}
