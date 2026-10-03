import { t } from '../model/I18n';
import { SwipeRow } from '../common/SwipeRow';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { McpOAuth } from '../services/McpOAuth';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ProductivityData, MemoryEntry, PromptTemplate, McpServer, validateProductivity } from '../model/Productivity';
import { McpClient } from '../services/McpClient';
import { Cancellation } from '../services/Cancellation';
import { CredentialStore } from '../services/CredentialStore';
import { Btn, Font, Radius, Space, Styles, shortTime } from '../common/Theme';
import { Banner, BottomBar, EmptyState, IconBadge, Segmented, Tag } from '../common/Widgets';

const TABS: string[] = ['memory', 'templates', 'mcp'];

@Component
export struct ProductivityPanel {
  @ObjectLink app: ChatViewModel;
  @State tab: string = 'memory';
  onUse: () => void = () => {};
  @State private editing: boolean = false;
  @State private swipeRow: string = '';
  @State private editingId: string = '';
  @State private name: string = '';
  @State private content: string = '';
  @State private scoped: boolean = false;
  @State private url: string = '';
  @State private token: string = '';
  @State private noAuth: boolean = true;
  @State private error: string = '';
  @State private busy: boolean = false;
  @State private testingId: string = '';
  @State private testId: string = '';
  @State private testMessage: string = '';
  @State private testOk: boolean = false;
  @State private oauthClientId: string = '';
  @State private oauthCallback: string = '';
  private async login(server: McpServer): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; let alias = '';
    try {
      alias = await McpOAuth.login(server, this.getUIContext().getHostContext() as common.UIAbilityContext, this.oauthClientId.trim());
      const data = this.snapshot(); const target = data.servers.find((item) => item.id === server.id && item.url === server.url);
      if (!target) { throw new Error(t("服务配置已变化，请重新登录。")); }
      const previous = target.credentialAlias; target.credentialAlias = alias; target.authType = 'oauth';
      if (!await this.app.saveProductivity(data)) { throw new Error(this.app.error); }
      alias = ''; if (previous) { await new CredentialStore().remove(previous); } this.toast(t("OAuth 登录成功"));
    } catch (error) { this.error = (error as Error).message; if (alias) { await new CredentialStore().remove(alias).catch(() => {}); } }
    finally { this.busy = false; this.oauthCallback = ''; }
  }
  private tabs: TabsController = new TabsController();
  private cancellation: Cancellation = new Cancellation();
  aboutToDisappear(): void { this.cancellation.cancel(); this.token = ''; }

  private locked(): boolean { return this.busy || this.app.busy; }
  private currentIndex(): number { return Math.max(0, TABS.indexOf(this.tab)); }
  private selectTab(index: number): void {
    if (this.tab === TABS[index]) { return; }
    this.swipeRow = ''; this.tab = TABS[index]; this.tabs.changeIndex(index);
  }
  private reset(): void {
    this.editingId = ''; this.name = ''; this.content = ''; this.url = ''; this.token = ''; this.scoped = false; this.noAuth = true; this.error = '';
  }
  private openEditor(): void { this.getUIContext().getFocusController().clearFocus(); this.editing = true; }
  private createEntry(): void { this.reset(); this.openEditor(); }
  private editMemory(item: MemoryEntry): void {
    this.reset(); this.editingId = item.id; this.content = item.content; this.scoped = !!item.threadId; this.openEditor();
  }
  private editTemplate(item: PromptTemplate): void {
    this.reset(); this.editingId = item.id; this.name = item.name; this.content = item.content; this.openEditor();
  }
  private editServer(item: McpServer): void {
    this.reset(); this.editingId = item.id; this.name = item.name; this.url = item.url; this.noAuth = !item.credentialAlias; this.openEditor();
  }
  private toast(message: string): void { this.getUIContext().getPromptAction().showToast({ message: message }); }
  private memories(): MemoryEntry[] {
    return this.app.productivity.memories.filter((item) => !item.threadId || item.threadId === this.app.active.id)
      .sort((a, b) => b.updatedAt - a.updatedAt);
  }
  private canSave(): boolean {
    if (this.locked()) { return false; }
    if (this.tab === 'memory') { return this.content.trim().length > 0; }
    if (this.tab === 'templates') { return this.name.trim().length > 0 && this.content.trim().length > 0; }
    return this.name.trim().length > 0 && this.url.trim().length > 0;
  }
  private snapshot(): ProductivityData { return JSON.parse(JSON.stringify(this.app.productivity)) as ProductivityData; }
  private async save(): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; const data = this.snapshot(); const id = this.editingId || util.generateRandomUUID();
    let newAlias = ''; let oldAlias = ''; const vault = new CredentialStore();
    try {
      if (this.tab === 'memory') {
        const memory: MemoryEntry = { id: id, content: this.content.trim(), threadId: this.scoped ? this.app.active.id : '', updatedAt: Date.now() };
        data.memories = data.memories.filter((item) => item.id !== id).concat([memory]);
      } else if (this.tab === 'templates') {
        const template: PromptTemplate = { id: id, name: this.name.trim(), content: this.content };
        const index = data.templates.findIndex((item) => item.id === id);
        if (index >= 0) { data.templates[index] = template; } else { data.templates.push(template); }
      } else {
        const existing = data.servers.find((item) => item.id === id); oldAlias = existing?.credentialAlias || '';
        const address = this.url.trim();
        let alias = '';
        if (!this.noAuth) {
          if (this.token.trim()) { newAlias = 'tinybot-mcp-' + util.generateRandomUUID(); alias = newAlias; }
          else if (existing && existing.url === address && oldAlias) { await vault.read(oldAlias); alias = oldAlias; }
          else { throw new Error(t("请输入 Bearer Token，或选择无需鉴权。修改服务地址后需要重新填写 Token。")); }
        }
        const server: McpServer = { id: id, name: this.name.trim(), url: address, enabled: existing?.enabled !== false, credentialAlias: alias,
          authType: existing?.authType === 'oauth' && address === existing.url && alias === oldAlias ? 'oauth' : undefined };
        const index = data.servers.findIndex((item) => item.id === id);
        if (index >= 0) { data.servers[index] = server; } else { data.servers.push(server); }
      }
      validateProductivity(data);
      if (newAlias) { await vault.write(newAlias, this.token.trim()); }
      if (!await this.app.saveProductivity(data)) { throw new Error(this.app.error); }
      if (oldAlias && !data.servers.some((item) => item.credentialAlias === oldAlias)) { try { await vault.remove(oldAlias); } catch (_) { /* Config is already committed. */ } }
      newAlias = ''; this.editing = false; this.reset(); this.toast(t("已保存"));
    } catch (error) {
      this.error = (error as Error).message;
      if (newAlias && !this.app.productivity.servers.some((item) => item.credentialAlias === newAlias)) {
        try { await vault.remove(newAlias); } catch (_) { /* Unreferenced secret can be removed later. */ }
      }
    } finally { this.busy = false; }
  }
  private remove(id: string, label: string): void {
    this.getUIContext().showAlertDialog({ title: t('删除{0}？', [label]), message: t("删除后将不再使用，且无法恢复。"),
      primaryButton: { value: t("取消"), action: () => {} },
      secondaryButton: { value: t("删除"), fontColor: $r('app.color.danger'), action: () => this.removeNow(id) } });
  }
  private async removeNow(id: string): Promise<void> {
    if (this.locked()) { return; }
    const data = this.snapshot(); const alias = data.servers.find((item) => item.id === id)?.credentialAlias || '';
    if (this.tab === 'memory') { data.memories = data.memories.filter((item) => item.id !== id); }
    else if (this.tab === 'templates') { data.templates = data.templates.filter((item) => item.id !== id); }
    else { data.servers = data.servers.filter((item) => item.id !== id); }
    if (await this.app.saveProductivity(data)) {
      if (this.tab === 'mcp' && alias) { try { await new CredentialStore().remove(alias); } catch (_) { /* No longer referenced. */ } }
      if (this.editingId === id) { this.editing = false; this.reset(); }
      this.toast(t("已删除"));
    } else { this.error = this.app.error; }
  }
  private async toggle(server: McpServer, value: boolean): Promise<void> {
    if (server.enabled === value) { return; }
    const data = this.snapshot(); const item = data.servers.find((item) => item.id === server.id);
    if (item) { item.enabled = value; if (!await this.app.saveProductivity(data)) { this.error = this.app.error; } }
  }
  private async test(server: McpServer): Promise<void> {
    if (this.testingId) { return; }
    this.testingId = server.id; this.testId = server.id; this.testMessage = ''; this.error = '';
    try {
      const tools = await new McpClient(server).list(this.cancellation);
      this.testOk = true;
      this.testMessage = t("连接成功 · ") + tools.length + t(" 个工具") + (tools.length ? '：' + tools.map((tool) => tool.name).join('、') : '');
    } catch (error) { this.testOk = false; this.testMessage = (error as Error).message; }
    finally { this.testingId = ''; }
  }

  @Builder
  caption(text: string) {
    Text(text).fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary')).width('100%')
      .padding({ left: 4, right: 4, top: Space.sm })
  }

  @Builder
  memoryTab() {
    List({ space: Space.md }) {
      ListItem() { this.caption(t("记忆会作为背景资料随每次请求发送给模型。可以对所有对话生效，或只用于当前对话。")) }
      if (this.memories().length === 0) {
        ListItem() { EmptyState({ icon: $r('sys.symbol.lightbulb'), title: t("还没有记忆"),
          caption: t("添加你的偏好、身份背景或常用约定；也可以长按聊天消息保存。") }) }
      }
      ForEach(this.memories(), (item: MemoryEntry) => {
        ListItem() {
          SwipeRow({ rowKey: 'memory-' + item.id, label: t('这条记忆'), activeRow: this.swipeRow,
            disabled: this.locked(), onOpen: (key: string) => { this.swipeRow = key; },
            onDelete: () => this.remove(item.id, t('这条记忆')) }) {
          Column({ space: Space.sm }) {
            Text(item.content).fontSize(15).lineHeight(22).maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').fontColor($r('app.color.text_primary'))
            Row({ space: Space.sm }) {
              Tag({ text: item.threadId ? t("仅本对话") : t("所有对话"), strong: !item.threadId })
              Tag({ text: item.automatic ? t("自动提取") : t("手动添加") })
              Blank()
              Text(shortTime(item.updatedAt)).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
            }.width('100%')
            if (item.sourceThreadId && item.sourceMessageId) {
              Button(t("查看记忆来源")).attributeModifier(Btn.textSmall).onClick(async () => {
                if (await this.app.openMessage(item.sourceThreadId || '', item.sourceMessageId || '')) { this.onUse(); }
              })
            }
          }.padding(Space.lg).width('100%').backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
          .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
          .onClick(() => { if (!this.locked()) { this.editMemory(item); } })
          }
        }
      }, (item: MemoryEntry) => item.id + item.updatedAt)
    }.width('100%').height('100%').padding({ left: Space.page, right: Space.page }).scrollBar(BarState.Off)
    .contentEndOffset(Space.lg).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  templateTab() {
    List({ space: Space.md }) {
      ListItem() { this.caption(t("正文中的 {{input}} 会替换为输入框中的草稿。")) }
      if (this.app.productivity.templates.length === 0) {
        ListItem() { EmptyState({ icon: $r('sys.symbol.doc_plaintext'), title: t("还没有模板"), caption: t("把常用的提问方式保存下来，一键套用。") }) }
      }
      ForEach(this.app.productivity.templates, (item: PromptTemplate) => {
        ListItem() {
          SwipeRow({ rowKey: 'template-' + item.id, label: item.name, activeRow: this.swipeRow,
            disabled: this.locked(), onOpen: (key: string) => { this.swipeRow = key; },
            onDelete: () => this.remove(item.id, t('这个模板')) }) {
          Row({ space: Space.md }) {
            IconBadge({ icon: $r('sys.symbol.doc_plaintext') })
            Column({ space: 4 }) {
              Text(item.name).fontSize(Font.body).fontWeight(FontWeight.Medium).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
              Text(item.content.replace(/\s+/g, ' ')).fontSize(13).lineHeight(19).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button(t("套用")).id('use-template-' + item.id).attributeModifier(Btn.tonalSmall)
              .enabled(!this.app.busy && !this.app.active.archived)
              .onClick(() => { this.app.useTemplate(item.id); this.onUse(); })
          }.padding(Space.lg).width('100%').backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
          .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
          .onClick(() => { if (!this.locked()) { this.editTemplate(item); } })
          }
        }
      }, (item: PromptTemplate) => JSON.stringify(item))
    }.width('100%').height('100%').padding({ left: Space.page, right: Space.page }).scrollBar(BarState.Off)
    .contentEndOffset(Space.lg).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  serverTab() {
    List({ space: Space.md }) {
      ListItem() { this.caption(t("支持 HTTPS Streamable HTTP、Bearer Token 与 OAuth 登录。每次远程工具调用都会请求确认。")) }
      if (this.busy) {
        ListItem() {
          Column({ space: Space.sm }) {
            Row({ space: Space.sm }) {
              LoadingProgress().width(18).height(18).color($r('app.color.accent'))
              Text(t("正在等待浏览器完成登录…")).fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
                .fontColor($r('app.color.on_accent_container'))
            }.width('100%')
            Text(t("如果浏览器没有自动返回，请复制地址栏中的完整回调地址并粘贴到这里。")).fontSize(Font.caption).lineHeight(18)
              .width('100%').fontColor($r('app.color.on_accent_container'))
            TextInput({ text: this.oauthCallback, placeholder: t("粘贴完整回调地址") }).id('mcp-oauth-callback')
              .attributeModifier(Styles.input).height(44).backgroundColor($r('app.color.surface'))
              .onChange((value) => { this.oauthCallback = value; })
            Button(t("完成登录")).id('mcp-oauth-finish').attributeModifier(Btn.primarySmall).height(40).width('100%')
              .enabled(this.oauthCallback.trim().length > 0).onClick(() => McpOAuth.receive(this.oauthCallback))
          }.width('100%').padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.accent_container'))
        }
      }
      if (this.app.productivity.servers.length === 0) {
        ListItem() { EmptyState({ icon: $r('sys.symbol.connection'), title: t("还没有 MCP 服务"), caption: t("添加远程 MCP 服务后，助手可以调用它提供的工具。") }) }
      }
      ForEach(this.app.productivity.servers, (item: McpServer) => {
        ListItem() {
          SwipeRow({ rowKey: 'mcp-' + item.id, label: item.name, activeRow: this.swipeRow,
            disabled: this.locked(), onOpen: (key: string) => { this.swipeRow = key; },
            onDelete: () => this.remove(item.id, t('这个 MCP 服务')) }) {
          Column({ space: 10 }) {
            Row({ space: Space.md }) {
              IconBadge({ icon: $r('sys.symbol.connection'),
                tint: item.enabled ? $r('app.color.accent') : $r('app.color.text_tertiary'),
                fill: item.enabled ? $r('app.color.accent_container') : $r('app.color.surface_variant') })
              Column({ space: 3 }) {
                Text(item.name).fontSize(Font.body).fontWeight(FontWeight.Medium).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
                Text(item.url).fontSize(Font.caption).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.text_tertiary'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: item.enabled }).id('toggle-mcp-' + item.id)
                .selectedColor($r('app.color.accent')).enabled(!this.locked())
                .onChange((value: boolean) => { this.toggle(item, value); })
            }.width('100%')
            Row({ space: 6 }) {
              Tag({ text: item.authType === 'oauth' ? 'OAuth' : item.credentialAlias ? 'Bearer Token' : t("无需鉴权") })
              if (this.app.active.disabledMcpIds.includes(item.id)) {
                Tag({ text: t("本对话已停用"), danger: true })
              }
            }.width('100%')
            Divider().strokeWidth(0.5).color($r('app.color.divider'))
            Row({ space: Space.xs }) {
              if (this.testingId === item.id) {
                LoadingProgress().width(16).height(16).color($r('app.color.accent')).margin({ left: 10 })
              }
              Button(this.testingId === item.id ? t("连接中…") : t("测试连接")).id('test-mcp-' + item.id).attributeModifier(Btn.textSmall)
                .padding({ left: 10, right: 10 }).enabled(!this.testingId).onClick(() => this.test(item))
              Button(t("OAuth 登录")).id('login-mcp-' + item.id).attributeModifier(Btn.textSmall).padding({ left: 10, right: 10 })
                .enabled(!this.locked()).onClick(() => this.login(item))
              Blank()
              Button(this.app.active.disabledMcpIds.includes(item.id) ? t("本对话启用") : t("本对话停用")).id('thread-mcp-' + item.id)
                .attributeModifier(Btn.textSmall).padding({ left: 10, right: 10 })
                .fontColor(this.app.active.disabledMcpIds.includes(item.id) ? $r('app.color.accent') : $r('app.color.text_secondary'))
                .enabled(!this.locked()).onClick(() => this.app.setThreadMcp(item.id, this.app.active.disabledMcpIds.includes(item.id)))
            }.width('100%').margin({ left: -10 })
            if (this.testId === item.id && this.testMessage.length > 0) {
              Row({ space: Space.sm }) {
                SymbolGlyph(this.testOk ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.exclamationmark_circle'))
                  .fontSize(16).fontColor([this.testOk ? $r('app.color.accent') : $r('app.color.danger')])
                Text(this.testMessage).fontSize(13).lineHeight(19).layoutWeight(1).maxLines(6)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
                  .fontColor(this.testOk ? $r('app.color.text_primary') : $r('app.color.danger'))
              }.width('100%').alignItems(VerticalAlign.Top).padding(10).borderRadius(Radius.sm)
              .backgroundColor(this.testOk ? $r('app.color.surface_variant') : $r('app.color.danger_container'))
            }
          }.padding({ left: Space.lg, right: Space.md, top: Space.md, bottom: 4 }).width('100%')
          .backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
          .onClick(() => { if (!this.locked()) { this.editServer(item); } })
          }
        }
      }, (item: McpServer) => JSON.stringify(item))
      if (this.app.productivity.servers.length > 0) {
        ListItem() {
          Column({ space: Space.sm }) {
            Text(t("OAuth 客户端 ID（可选）")).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.oauthClientId, placeholder: t("已在服务端注册的公开客户端 ID") }).id('mcp-oauth-client')
              .attributeModifier(Styles.input).height(44).onChange((value) => { this.oauthClientId = value; })
            Text(t("用于 OAuth 登录。留空时向服务动态注册客户端。")).fontSize(Font.caption).fontColor($r('app.color.text_tertiary')).width('100%')
          }.width('100%').padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
        }
      }
    }.width('100%').height('100%').padding({ left: Space.page, right: Space.page }).scrollBar(BarState.Off)
    .contentEndOffset(Space.lg).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  fieldLabel(text: string, top: number) {
    Text(text).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').padding({ left: 4, top: top })
  }

  @Builder
  scopeChip(label: string, value: boolean) {
    Text(label).fontSize(14).height(36).layoutWeight(1).textAlign(TextAlign.Center).borderRadius(18)
      .fontColor(this.scoped === value ? $r('app.color.on_accent_container') : $r('app.color.text_secondary'))
      .backgroundColor(this.scoped === value ? $r('app.color.accent_container') : $r('app.color.surface'))
      .border({ width: this.scoped === value ? 0 : 0.5, color: $r('app.color.divider') })
      .onClick(() => { this.scoped = value; })
  }

  @Builder
  editorSheet() {
    Column() {
      Scroll() {
        Column({ space: Space.sm }) {
          if (this.tab !== 'memory') {
            this.fieldLabel(this.tab === 'mcp' ? t("服务名称") : t("模板名称"), 0)
            TextInput({ text: this.name, placeholder: this.tab === 'mcp' ? t("例如：公司知识库") : t("例如：会议纪要") })
              .id('productivity-name').attributeModifier(Styles.input).backgroundColor($r('app.color.surface'))
              .maxLength(40).onChange((value) => { this.name = value; })
          }
          if (this.tab === 'mcp') {
            this.fieldLabel(t("服务地址"), Space.sm)
            TextInput({ text: this.url, placeholder: 'https://example.com/mcp' }).id('mcp-url').type(InputType.URL)
              .attributeModifier(Styles.input).backgroundColor($r('app.color.surface'))
              .onChange((value) => { this.url = value; })
            Row({ space: Space.md }) {
              Column({ space: 2 }) {
                Text(t("无需鉴权")).fontSize(Font.body).fontColor($r('app.color.text_primary'))
                Text(t("关闭后填写 Bearer Token，Token 保存在系统安全存储中。")).fontSize(Font.caption)
                  .fontColor($r('app.color.text_secondary'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.noAuth }).id('mcp-no-auth').selectedColor($r('app.color.accent'))
                .onChange((value) => { this.noAuth = value; })
            }.width('100%').padding({ left: Space.lg, right: Space.md, top: 10, bottom: 10 }).margin({ top: Space.sm })
            .borderRadius(Radius.sm).backgroundColor($r('app.color.surface'))
            if (!this.noAuth) {
              TextInput({ text: this.token, placeholder: this.editingId ? t("留空则保留已有 Token") : 'Bearer Token' })
                .id('mcp-token').type(InputType.Password).attributeModifier(Styles.input).backgroundColor($r('app.color.surface'))
                .onChange((value) => { this.token = value; })
            }
          } else {
            if (this.tab === 'templates') { this.fieldLabel(t("模板正文"), Space.sm) }
            TextArea({ text: this.content,
              placeholder: this.tab === 'memory' ? t("例如：回答优先使用中文，代码示例使用 ArkTS。") : t("例如：请把以下内容整理成会议纪要：\n\n{{input}}") })
              .id('productivity-content').attributeModifier(Styles.area).backgroundColor($r('app.color.surface'))
              .height(this.tab === 'memory' ? 160 : 220).fontSize(15).showCounter(true)
              .maxLength(this.tab === 'memory' ? 2000 : 12000).onChange((value) => { this.content = value; })
            if (this.tab === 'templates') {
              Button(t("插入 {{input}} 占位")).attributeModifier(Btn.textSmall).enabled(!this.content.includes('{{input}}'))
                .onClick(() => { this.content = this.content + (this.content.length > 0 ? '\n\n' : '') + '{{input}}'; })
            }
            if (this.tab === 'memory') {
              this.fieldLabel(t("生效范围"), Space.sm)
              Row({ space: Space.sm }) {
                this.scopeChip(t("所有对话"), false)
                this.scopeChip(t("仅本对话"), true)
              }.width('100%').id('memory-scope')
            }
          }
          if (this.error.length > 0) {
            Banner({ text: this.error, compId: 'productivity-error' }).margin({ top: Space.sm })
          }
        }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.lg })
      }.layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      BottomBar() {
        Row({ space: Space.md }) {
          if (this.editingId.length > 0) {
            Button(t("删除")).attributeModifier(Btn.danger).enabled(!this.locked())
              .onClick(() => this.remove(this.editingId, this.tab === 'memory' ? t("这条记忆") : this.tab === 'templates' ? t("这个模板") : t("这个 MCP 服务")))
          }
          Button(this.busy ? t("正在保存…") : t("保存")).id('save-productivity').attributeModifier(Btn.primary).layoutWeight(1)
            .enabled(this.canSave()).onClick(() => this.save())
        }.width('100%')
      }
    }.width('100%').height('100%')
  }

  private sheetTitle(): string {
    return this.tab === 'memory' ? (this.editingId ? t('编辑记忆') : t('添加记忆')) :
      this.tab === 'templates' ? (this.editingId ? t('编辑模板') : t('新建模板')) :
      (this.editingId ? t('编辑 MCP 服务') : t('添加 MCP 服务'));
  }

  build() {
    Column() {
      Segmented({ options: [t("记忆"), t("模板"), 'MCP'], selected: this.currentIndex(), compIdPrefix: 'tab',
        onSelect: (index: number) => this.selectTab(index) })
        .padding({ left: Space.page, right: Space.page, top: Space.xs, bottom: Space.xs })
      Tabs({ index: this.currentIndex(), controller: this.tabs }) {
        TabContent() { this.memoryTab() }
        TabContent() { this.templateTab() }
        TabContent() { this.serverTab() }
      }.barHeight(0).layoutWeight(1).animationDuration(250).scrollable(false)
      .onChange((index: number) => { this.swipeRow = ''; this.tab = TABS[index]; })
      if (this.error.length > 0 && !this.editing) {
        Banner({ text: this.error }).padding({ left: Space.page, right: Space.page })
      }
      BottomBar() {
        Button(this.tab === 'memory' ? t("添加记忆") : this.tab === 'templates' ? t("新建模板") : t("添加 MCP 服务"))
          .id('add-productivity').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.locked() && (this.tab !== 'mcp' || this.app.productivity.servers.length < 10))
          .onClick(() => this.createEntry())
      }
    }.width('100%').height('100%')
    .bindSheet($$this.editing, this.editorSheet(), {
      title: { title: this.sheetTitle() }, detents: [SheetSize.LARGE], dragBar: true,
      backgroundColor: $r('app.color.page_background'),
      onDisappear: () => { this.token = ''; this.error = ''; }
    })
  }
}
