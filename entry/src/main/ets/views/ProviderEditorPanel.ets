import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { discoverModels } from '../services/ModelDiscovery';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';
import { Btn, Motion, Radius, Space, Styles, protocolName } from '../common/Theme';
import { Banner, BottomBar, GroupCard, IconButton, NavRow, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

@Component
export struct ProviderEditorPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink editor: ProviderEditorViewModel;
  onSaved: () => void = () => {};
  @State private discovering: boolean = false;
  @State private advanced: boolean = false;
  @State private replacingKey: boolean = false;
  @State private attempted: boolean = false;
  @State private showModels: boolean = false;
  @State private showDiscovery: boolean = false;
  @State private modelError: string = '';
  @State private foundModels: string[] = [];
  @State private selectedModels: string[] = [];
  @State private modelQuery: string = '';
  private alive: boolean = true;
  private scroller: Scroller = new Scroller();
  private protocols: string[] = ['chat-completions', 'responses', 'anthropic-messages'];
  // Card labels stay short to fit three across; the full name shows in the caption below.
  private protocolLabels: string[] = ['Chat Completions', 'Responses', 'Messages'];
  private protocolLogos: Resource[] = [$r('app.media.logo_openai'), $r('app.media.logo_openai'), $r('app.media.logo_anthropic')];

  aboutToAppear(): void { this.alive = true; }
  aboutToDisappear(): void { this.alive = false; }
  private locked(): boolean { return this.app.busy || this.discovering; }
  private async openApiKeyPage(): Promise<void> {
    const url = this.editor.apiKeyUrl;
    if (!url || this.locked()) { return; }
    try {
      await (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .startAbility({ action: 'ohos.want.action.viewData', uri: url });
    } catch (_) {
      if (this.alive) { this.getUIContext().getPromptAction().showToast({ message: t('无法打开系统浏览器。') }); }
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
      this.foundModels = models; this.selectedModels = []; this.modelQuery = ''; this.modelError = '';
      this.getUIContext().getFocusController().clearFocus(); this.showDiscovery = true;
    } catch (error) { if (this.alive) { this.editor.error = (error as Error).message; } }
    finally { if (this.alive) { this.discovering = false; } }
  }
  private async save(): Promise<void> {
    if (this.locked()) { return; }
    if (this.editor.modelInput.trim()) { this.addManual(); if (this.modelError) { this.showModels = true; return; } }
    this.attempted = true;
    const invalid = ['name', 'url', 'key', 'models', 'context'].find((field: string) => this.editor.fieldError(field).length > 0);
    if (invalid) {
      if (invalid === 'context') { this.advanced = true; }
      this.getUIContext().getPromptAction().showToast({ message: t('请检查标出的设置项。') });
      if (invalid === 'models') { this.showModels = true; return; }
      setTimeout(() => {
        if (!this.alive) { return; }
        this.scroller.scrollEdge(invalid === 'context' ? Edge.Bottom : Edge.Top);
        this.getUIContext().getFocusController().requestFocus(invalid === 'context' ? 'context-window' : 'provider-' + invalid);
      }, 100);
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
    Text(text).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').margin({ bottom: 6 })
  }
  @Builder
  fieldError(field: string) {
    if (this.attempted && this.editor.fieldError(field)) {
      Text(this.editor.fieldError(field)).id('provider-field-error-' + field).fontSize(12).lineHeight(18)
        .fontColor($r('app.color.danger')).width('100%').margin({ top: 6 })
    }
  }
  private protocolHint(protocol: string): string {
    return protocol === 'chat-completions' ? t('兼容大多数 OpenAI 格式的服务') :
      protocol === 'responses' ? t('OpenAI 新一代接口') : t('Claude 模型使用的接口');
  }
  // Three side-by-side cards with the vendor mark; the selected card takes the accent outline.
  @Builder
  protocolPicker() {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        ForEach(this.protocols, (protocol: string, index: number) => {
          Column({ space: 6 }) {
            Image(this.protocolLogos[index]).width(24).height(24).objectFit(ImageFit.Contain)
              .fillColor(this.editor.protocol === protocol ? $r('app.color.accent') : $r('app.color.text_secondary'))
            Text(this.protocolLabels[index]).fontSize(13).lineHeight(17).maxLines(2).textAlign(TextAlign.Center)
              .fontWeight(this.editor.protocol === protocol ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.editor.protocol === protocol ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
          }
          .id('provider-protocol-' + protocol).layoutWeight(1).constraintSize({ minHeight: 76 })
          .justifyContent(FlexAlign.Center).padding({ left: 6, right: 6, top: 10, bottom: 10 })
          .borderRadius(Radius.md)
          .backgroundColor(this.editor.protocol === protocol ? $r('app.color.accent_tint') : $r('app.color.surface_variant'))
          .border({ width: 1.5, color: this.editor.protocol === protocol ? $r('app.color.accent') : Color.Transparent })
          .animation({ duration: Motion.fast, curve: Motion.standard })
          .clickEffect(Motion.press)
          .accessibilityGroup(true)
          .accessibilityText(protocolName(protocol) + (this.editor.protocol === protocol ? t("，已选中") : ''))
          .onClick(() => { this.editor.changeProtocol(protocol); })
        }, (protocol: string) => protocol)
      }.width('100%').alignItems(VerticalAlign.Top)
      Text(protocolName(this.editor.protocol) + ' · ' + this.protocolHint(this.editor.protocol))
        .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).width('100%')
    }.width('100%')
  }
  private confirmDelete(): void {
    this.getUIContext().showAlertDialog({ title: t('删除模型服务？'),
      message: t('删除这份服务配置及其密钥，保留完整对话。使用它的会话需要重新选择模型。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('删除'), fontColor: $r('app.color.danger'), action: async () => {
        if (await this.app.deleteProvider(this.editor.id)) { this.onSaved(); }
      } } });
  }

  @Builder
  serviceActions() {
    Menu() {
      MenuItem({ content: t('删除此服务') }).id('delete-provider-' + this.editor.id)
        .contentFontColor($r('app.color.danger')).enabled(!this.locked()).onClick(() => this.confirmDelete())
    }
  }

  @Builder
  modelRow(id: string) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(14).fontColor([$r('app.color.accent')])
      Text(id).fontSize(14).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1).fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice)
      IconButton({ icon: $r('sys.symbol.xmark'), label: t('移除模型 {0}', [id]), compId: 'remove-model-' + id,
        iconSize: 12, disabled: this.locked(), onTap: () => this.editor.removeModel(id) })
    }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 16, right: 4 })
  }
  @Builder
  modelsSheet() {
    Column({ space: Space.md }) {
      Column({ space: 8 }) {
        Text(t('添加模型 ID')).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
        TextArea({ text: this.editor.modelInput, placeholder: t('粘贴模型 ID，支持换行或逗号分隔') }).id('provider-models')
          .attributeModifier(Styles.area).constraintSize({ minHeight: 60, maxHeight: 104 }).maxLength(10000)
          .onChange((value: string) => { this.editor.modelInput = value; this.modelError = ''; })
        Button(t('添加到列表')).id('add-manual-models').attributeModifier(Btn.tonal).width('100%')
          .enabled(this.editor.modelInput.trim().length > 0).onClick(() => this.addManual())
        if (this.modelError) { Banner({ text: this.modelError }) }
        this.fieldError('models')
      }.padding({ left: Space.page, right: Space.page })
      List() {
        ForEach(this.editor.modelList, (id: string) => { ListItem() { this.modelRow(id) } }, (id: string) => id)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      BottomBar() {
        Button(t('完成 · {0} 个模型', [this.editor.modelList.length])).id('finish-models').attributeModifier(Btn.primary).width('100%')
          .onClick(() => {
            if (this.editor.modelInput.trim()) { this.addManual(); if (this.modelError) { return; } }
            this.getUIContext().getFocusController().clearFocus(); this.showModels = false;
          })
      }
    }.height('100%').width('100%').padding({ top: 8, bottom: 24 })
  }
  @Builder
  discoverySheet() {
    Column({ space: Space.md }) {
      Search({ value: this.modelQuery, placeholder: t('搜索模型 ID') }).id('discovered-model-search').height(44)
        .margin({ left: Space.page, right: Space.page }).onChange((value: string) => { this.modelQuery = value; })
      Text(t('只添加你需要的模型，已有模型会保留。')).fontSize(13).fontColor($r('app.color.text_secondary'))
        .padding({ left: Space.page, right: Space.page }).width('100%')
      if (this.matches().length === 0) { Text(t('没有匹配的模型')).fontColor($r('app.color.text_secondary')).padding(16) }
      List() {
        ForEach(this.matches(), (id: string) => {
          ListItem() {
            Row({ space: 8 }) {
              Checkbox({ name: id }).select(this.editor.modelList.includes(id) || this.selectedModels.includes(id))
                .enabled(!this.editor.modelList.includes(id)).selectedColor($r('app.color.accent'))
                .onChange((value: boolean) => this.toggleFound(id, value)).accessibilityText(id)
              Text(id).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.editor.modelList.includes(id)) { Text(t('已添加')).fontSize(12).fontColor($r('app.color.text_secondary')) }
            }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 12, right: 16 })
            .onClick(() => { if (!this.editor.modelList.includes(id)) { this.toggleFound(id, !this.selectedModels.includes(id)); } })
          }
        }, (id: string) => id)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      BottomBar() {
        Column({ space: 8 }) {
          if (this.modelError) { Banner({ text: this.modelError }) }
          Button(t('添加所选模型（{0}）', [this.selectedModels.length])).id('add-discovered-models')
            .attributeModifier(Btn.primary).width('100%').enabled(this.selectedModels.length > 0)
            .onClick(() => {
              try { this.editor.addModels(this.selectedModels.join('\n')); this.showDiscovery = false; }
              catch (error) { this.modelError = (error as Error).message; }
            })
        }
      }
    }.height('100%').width('100%').padding({ top: 8, bottom: 24 })
  }

  build() {
    Column() {
      if (this.editor.id.length > 0) {
        Row() {
          Blank()
          Button(t('更多操作')).id('provider-more-actions').attributeModifier(Btn.text).height(44)
            .enabled(!this.locked()).bindMenu(this.serviceActions)
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
                TextInput({ text: this.editor.name, placeholder: t('例如：我的 DeepSeek、公司代理') }).id('provider-name')
                  .attributeModifier(Styles.input).maxLength(80).enterKeyType(EnterKeyType.Next)
                  .onSubmit(() => { this.getUIContext().getFocusController().requestFocus('provider-url'); })
                  .onChange((value: string) => { this.editor.name = value; })
                this.fieldError('name')
              }
              Column() {
                this.label(t('服务地址'))
                TextInput({ text: this.editor.baseUrl, placeholder: 'https://api.example.com/v1' }).id('provider-url')
                  .attributeModifier(Styles.input).type(InputType.URL).maxLength(1024)
                  .onChange((value: string) => { this.editor.baseUrl = value; })
                this.fieldError('url')
                if (this.editor.baseUrl.startsWith('http://')) {
                  Text(t('HTTP 连接未加密，仅适用于可信网络中的本地模型。')).fontSize(12).width('100%')
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
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
                    Text(t('密钥已保存')).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
                    Button(t('更换')).id('replace-provider-key').attributeModifier(Btn.text).height(44).enabled(!this.locked())
                      .onClick(() => { this.replacingKey = true; })
                  }.padding({ left: 16, right: 4 }).width('100%').constraintSize({ minHeight: 56 })
                } else {
                  Column() {
                    TextInput({ text: this.editor.apiKey, placeholder: this.editor.canKeepKey ? t('留空保留原密钥') : t('填写 API Key') })
                      .id('provider-key').attributeModifier(Styles.input).type(InputType.Password).showPasswordIcon(true)
                      .copyOption(CopyOptions.None).maxLength(512).onChange((value: string) => { this.editor.apiKey = value; })
                    this.fieldError('key')
                    if (this.editor.hasSavedKey && !this.editor.canKeepKey && !this.attempted) {
                      Text(t('服务基础地址已改变，请重新填写密钥。')).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 6 })
                    }
                  }.padding(12)
                }
              }
            }
          }
          if (this.editor.apiKeyUrl) {
            Button() {
              Row({ space: 6 }) {
                Text(t('获取 API Key')).fontSize(14).fontColor($r('app.color.accent'))
                SymbolGlyph($r('sys.symbol.arrow_up_right')).fontSize(12).fontColor([$r('app.color.accent')])
              }
            }.id('get-provider-api-key').attributeModifier(Btn.text).height(44)
              .accessibilityText(t('获取 API Key，在浏览器中打开'))
              .enabled(!this.locked()).onClick(() => this.openApiKeyPage())
          }
          SectionHeader({ title: t('模型'), caption: t('已添加 {0} 个模型', [this.editor.modelList.length]) })
          GroupCard() {
            Column() {
              ForEach(this.editor.modelList.slice(0, 3), (id: string) => { this.modelRow(id); RowDivider() }, (id: string) => id)
              if (this.editor.modelList.length > 3) {
                NavRow({ title: t('查看全部 {0} 个模型', [this.editor.modelList.length]), compId: 'view-all-models',
                  disabled: this.locked(), onTap: () => { this.modelError = ''; this.showModels = true; } })
                RowDivider()
              }
              if (this.editor.modelList.length === 0) {
                Text(t('添加至少一个模型，即可开始对话。')).fontSize(13).fontColor($r('app.color.text_secondary')).padding(16).width('100%')
              }
              Row({ space: 8 }) {
                Button(this.discovering ? t('正在发现模型…') : t('获取模型')).id('discover-models').attributeModifier(Btn.tonal).layoutWeight(1)
                  .enabled(!this.locked()).onClick(() => this.discover())
                  .bindSheet($$this.showDiscovery, this.discoverySheet(), { title: { title: t('选择要添加的模型') }, detents: [SheetSize.LARGE], dragBar: true,
                    keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: $r('app.color.page_background') })
                Button(t('手动添加')).id('manage-provider-models')
                  .attributeModifier(Btn.text).height(44).layoutWeight(1).enabled(!this.locked())
                  .onClick(() => { this.modelError = ''; this.showModels = true; })
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
                      TextInput({ text: this.editor.contextWindow, placeholder: t('留空使用模型默认值') }).id('context-window').attributeModifier(Styles.input)
                        .type(InputType.Number).maxLength(7).onChange((value: string) => { this.editor.contextWindow = value; })
                      this.fieldError('context')
                      Text(t('留空按模型设置：通用 200k，DeepSeek V4 / Flash、GLM 5.3 系列 1M。填写数值覆盖服务默认值；单模型设置优先。')).fontSize(12).lineHeight(18)
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
          Button(this.app.busy ? t('正在保存…') : this.editor.id ? t('保存更改') : t('保存服务')).id('save-provider')
            .attributeModifier(Btn.primary).width('100%').enabled(!this.locked()).onClick(() => this.save())
        }
      }
    }.width('100%').height('100%')
    .bindSheet($$this.showModels, this.modelsSheet(), { title: { title: t('管理模型') }, detents: [SheetSize.LARGE], dragBar: true,
      keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: $r('app.color.page_background') })
  }
}
