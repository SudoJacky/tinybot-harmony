import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { AssistantOptions, ModelCapability, defaultAssistantOptions } from '../model/AssistantOptions';
import { ModelReference } from '../model/ProviderProfiles';
import { ProductivityData } from '../model/Productivity';
import { RequestUsage } from '../model/Usage';
import { UsageLedger } from '../services/UsageLedger';
import { exportBackup, readBackup } from '../services/Backup';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Radius, Space, compactNumber, shortTime } from '../common/Theme';
import { Banner, BottomBar, EmptyState, GroupCard, NavRow, RowDivider, SectionHeader, Segmented, StatTile, SwitchRow, Tag } from '../common/Widgets';

const TABS: string[] = ['settings', 'usage', 'backup'];
const REASONING: string[] = ['default', 'low', 'medium', 'high'];
function REASONING_NAMES(): string[] { return [t("服务默认"), t("低强度"), t("中强度"), t("高强度")]; }
function STATUS_NAMES(): Record<string, string> { return { 'complete': t("完成"), 'failed': t("失败"), 'cancelled': t("已取消"), 'running_or_unknown': t("未结束") }; }

@Component
export struct AssistantPanel {
  @ObjectLink app: ChatViewModel;
  @State tab: string = 'settings';
  @State private options: AssistantOptions = defaultAssistantOptions();
  @State private capabilityIndex: number = 0;
  @State private images: boolean = true;
  @State private usage: boolean = false;
  @State private reasoning: string = 'default';
  @State private contextWindow: string = '32768';
  @State private records: RequestUsage[] = [];
  @State private visible: number = 30;
  @State private filter: string = '';
  @State private busy: boolean = false;
  @State private error: string = '';
  private tabs: TabsController = new TabsController();
  aboutToAppear(): void { this.options = JSON.parse(JSON.stringify(this.app.productivity.options || defaultAssistantOptions())) as AssistantOptions; this.records = UsageLedger.list(); this.loadCapability(); }
  private choices(kind: string = ''): string[] { return [kind === 'image' ? t("未启用") : t("跟随当前模型")].concat(this.app.modelChoices.map((item) => item.providerName + ' · ' + item.modelId)); }
  private reference(index: number): ModelReference | undefined { const item = this.app.modelChoices[index - 1]; return item ? { providerId: item.providerId, modelId: item.modelId } : undefined; }
  private supportsReasoning(): boolean { return this.app.providerProfiles.find((item) => item.id === this.reference(this.capabilityIndex + 1)?.providerId)?.protocol !== 'anthropic-messages'; }
  private chosen(reference?: ModelReference): number { return reference ? this.app.modelChoices.findIndex((item) => item.providerId === reference.providerId && item.modelId === reference.modelId) + 1 : 0; }
  private loadCapability(): void {
    const reference = this.reference(this.capabilityIndex + 1);
    const item = this.options.capabilities.find((item) => item.providerId === reference?.providerId && item.modelId === reference?.modelId);
    this.images = item?.images !== false; this.usage = item?.requestUsage === true; this.reasoning = this.supportsReasoning() ? item?.reasoning || 'default' : 'default';
    this.contextWindow = String(item?.contextWindow || this.app.providerProfiles.find((item) => item.id === reference?.providerId)?.contextWindow || 32768);
  }
  private async save(): Promise<void> {
    this.error = ''; const extras = JSON.parse(JSON.stringify(this.app.productivity)) as ProductivityData;
    const reference = this.reference(this.capabilityIndex + 1);
    if (reference) {
      const capability: ModelCapability = { providerId: reference.providerId, modelId: reference.modelId, images: this.images,
        reasoning: this.reasoning, requestUsage: this.usage, contextWindow: Number(this.contextWindow) };
      this.options.capabilities = this.options.capabilities.filter((item) => item.providerId !== reference.providerId || item.modelId !== reference.modelId).concat([capability]);
    }
    extras.options = this.options;
    if (!await this.app.saveProductivity(extras)) { this.error = this.app.error; }
    else { this.getUIContext().getPromptAction().showToast({ message: t("助手设置已保存") }); }
  }
  private async backup(restore: boolean): Promise<void> {
    this.busy = true; this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (restore) { const data = await readBackup(context); if (data) { if (!await this.app.importSnapshot(data)) { throw new Error(this.app.error); } this.getUIContext().getPromptAction().showToast({ message: t("备份已恢复为独立副本") }); } }
      else { await exportBackup(context, this.app.exportSnapshot()); }
    } catch (error) { this.error = (error as Error).message; }
    finally { this.busy = false; }
  }
  private filtered(): RequestUsage[] { return this.records.filter((item) => !this.filter || (item.provider + '/' + item.model).toLowerCase().includes(this.filter.toLowerCase())); }
  private totals(): number[] {
    let input = 0; let output = 0; let unknown = 0;
    for (const item of this.filtered()) { if (item.tokens) { input += item.tokens.input; output += item.tokens.output; } else { unknown++; } }
    return [input, output, unknown];
  }
  private tokens(item: RequestUsage): string {
    const tokens = item.tokens;
    if (!tokens) { return t("Token 未报告"); }
    return t("输入 ") + compactNumber(tokens.input) + (tokens.cached ? t("（缓存 ") + compactNumber(tokens.cached) + '）' : '') +
      t(" · 输出 ") + compactNumber(tokens.output) + (tokens.reasoning ? t("（推理 ") + compactNumber(tokens.reasoning) + '）' : '');
  }
  private timing(item: RequestUsage): string {
    const tokens = item.tokens; const generation = item.firstTokenMs === undefined ? undefined : Math.max(1, item.durationMs - item.firstTokenMs);
    return (item.durationMs / 1000).toFixed(1) + 's' + (item.firstTokenMs === undefined ? '' : t(" · 首字 ") + (item.firstTokenMs / 1000).toFixed(1) + 's') +
      (tokens && generation ? ' · ' + (tokens.output * 1000 / generation).toFixed(1) + ' Token/s' : '');
  }
  private currentIndex(): number { return Math.max(0, TABS.indexOf(this.tab)); }
  private selectTab(index: number): void {
    if (this.tab === TABS[index]) { return; }
    this.getUIContext().getFocusController().clearFocus();
    this.tab = TABS[index]; this.tabs.changeIndex(index);
  }
  private setRoute(kind: string, index: number): void {
    const chosen = this.reference(index);
    if (kind === 'fast') { this.options.fast = chosen; } else if (kind === 'deep') { this.options.deep = chosen; }
    else if (kind === 'vision') { this.options.vision = chosen; } else if (kind === 'memory') { this.options.memory = chosen; }
    else { this.options.image = chosen; }
  }

  @Builder
  choiceMenu(options: string[], selected: number, onSelect: (index: number) => void) {
    Menu() {
      ForEach(options, (label: string, index: number) => {
        MenuItem({ content: label }).selected(index === selected).selectIcon(true).onClick(() => onSelect(index))
      }, (label: string, index: number) => index + label)
    }
  }

  // Tappable row showing the current choice; the full list opens as a menu.
  @Builder
  choiceRow(title: string, subtitle: string, options: string[], selected: number, enabled: boolean, onSelect: (index: number) => void) {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(title).fontSize(Font.body).fontColor($r('app.color.text_primary'))
        if (subtitle.length > 0) {
          Text(subtitle).fontSize(Font.caption).lineHeight(17).fontColor($r('app.color.text_secondary'))
        }
      }.alignItems(HorizontalAlign.Start).flexShrink(0).constraintSize({ maxWidth: '55%' })
      Text(options[selected] || options[0] || '').fontSize(13).maxLines(2).textAlign(TextAlign.End).layoutWeight(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(selected > 0 ? $r('app.color.accent') : $r('app.color.text_tertiary'))
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: Space.lg, right: Space.lg, top: 10, bottom: 10 })
    .opacity(enabled ? 1 : 0.4).enabled(enabled)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .bindMenu(this.choiceMenu(options, selected, onSelect))
  }

  @Builder
  settingsTab() {
    Column() {
      Scroll() {
        Column() {
          SectionHeader({ title: t("记忆与任务") })
          GroupCard() {
            Column() {
              SwitchRow({ title: t("自动提取长期记忆"), subtitle: t("从成功完成的对话中提取事实；会额外调用一次模型。"), compId: 'auto-memory',
                isOn: this.options.autoMemory, onChange: (value) => { this.options.autoMemory = value; } })
              RowDivider()
              SwitchRow({ title: t("只读任务"), subtitle: t("阻止修改文件、调用远程工具和生成图片。"), compId: 'read-only',
                isOn: this.options.readOnly, onChange: (value) => { this.options.readOnly = value; } })
              RowDivider()
              SwitchRow({ title: t("任务结束后保存结果"), subtitle: t("把成功的回答归档到工作区的“任务结果”目录。"), compId: 'save-summary',
                isOn: this.options.saveSummary, onChange: (value) => { this.options.saveSummary = value; } })
            }
          }
          SectionHeader({ title: t("按任务选择模型"), caption: t("图片交给视觉模型；长问题和分析类任务交给深度模型，其余使用快速模型。") })
          GroupCard() {
            Column() {
              SwitchRow({ title: t("自动选择模型"), compId: 'auto-route', isOn: this.options.autoRoute,
                onChange: (value) => { this.options.autoRoute = value; } })
              RowDivider()
              this.choiceRow(t("快速任务"), '', this.choices(), this.chosen(this.options.fast), this.options.autoRoute,
                (index: number) => this.setRoute('fast', index))
              RowDivider()
              this.choiceRow(t("深度任务"), '', this.choices(), this.chosen(this.options.deep), this.options.autoRoute,
                (index: number) => this.setRoute('deep', index))
              RowDivider()
              this.choiceRow(t("图片理解"), '', this.choices(), this.chosen(this.options.vision), this.options.autoRoute,
                (index: number) => this.setRoute('vision', index))
            }
          }
          SectionHeader({ title: t("专用模型") })
          GroupCard() {
            Column() {
              this.choiceRow(t("记忆整理"), t("提炼与合并长期记忆"), this.choices(), this.chosen(this.options.memory), true,
                (index: number) => this.setRoute('memory', index))
              RowDivider()
              this.choiceRow(t("图片生成"), t("OpenAI 兼容的图片接口"), this.choices('image'), this.chosen(this.options.image), true,
                (index: number) => this.setRoute('image', index))
            }
          }
          SectionHeader({ title: t("模型能力"), caption: t("切换到另一个模型前，请先保存当前修改。") })
          if (this.app.modelChoices.length) {
            GroupCard() {
              Column() {
                this.choiceRow(t("模型"), '', this.choices().slice(1), this.capabilityIndex, true,
                  (index: number) => { this.capabilityIndex = index; this.loadCapability(); })
                RowDivider()
                SwitchRow({ title: t("支持图片输入"), compId: 'capability-images', isOn: this.images, onChange: (value) => { this.images = value; } })
                RowDivider()
                SwitchRow({ title: t("请求流式用量"), subtitle: t("适用于支持 stream_options 的 Chat Completions 服务。"), compId: 'capability-usage',
                  isOn: this.usage, onChange: (value) => { this.usage = value; } })
                RowDivider()
                this.choiceRow(t("推理强度"), this.supportsReasoning() ? '' : t("Anthropic 使用服务默认设置"), REASONING_NAMES(),
                  Math.max(0, REASONING.indexOf(this.reasoning)), this.supportsReasoning(),
                  (index: number) => { this.reasoning = REASONING[index]; })
                RowDivider()
                Row({ space: Space.md }) {
                  Text(t("上下文窗口")).fontSize(Font.body).fontColor($r('app.color.text_primary'))
                  TextInput({ text: this.contextWindow, placeholder: '32768' }).id('capability-context').type(InputType.Number)
                    .layoutWeight(1).height(40).fontSize(15).textAlign(TextAlign.End).backgroundColor(Color.Transparent)
                    .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_tertiary'))
                    .onChange((value) => { this.contextWindow = value; })
                  Text('Token').fontSize(13).fontColor($r('app.color.text_tertiary'))
                }.width('100%').height(56).padding({ left: Space.lg, right: Space.lg })
              }
            }
          } else {
            GroupCard() {
              EmptyState({ icon: $r('sys.symbol.cloud'), title: t("还没有可用的模型"), caption: t("先在“设置 › 模型服务”中添加并启用服务。") })
            }
          }
          if (this.error) { Banner({ text: this.error }).margin({ top: Space.md }) }
        }.width('100%').padding({ left: Space.page, right: Space.page, bottom: Space.lg })
      }.layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      BottomBar() {
        Button(this.app.busy ? t("请等待当前任务完成") : t("保存")).id('save-assistant-options').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.busy && !this.busy).onClick(() => this.save())
      }
    }.width('100%').height('100%')
  }

  @Builder
  usageRow(item: RequestUsage) {
    Column({ space: 6 }) {
      Row({ space: Space.sm }) {
        Text(item.model).fontSize(15).fontWeight(FontWeight.Medium).maxLines(1).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        if (item.status !== 'complete') {
          Tag({ text: STATUS_NAMES()[item.status] || item.status, danger: item.status === 'failed' })
        }
        Text(shortTime(item.startedAt)).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
      }.width('100%')
      Text(this.tokens(item)).fontSize(13).width('100%').fontColor($r('app.color.text_secondary'))
      Text(item.provider + ' · ' + this.timing(item)).fontSize(Font.caption).maxLines(1).width('100%')
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
    }.width('100%').padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
  }

  @Builder
  usageTab() {
    List({ space: 0 }) {
      ListItem() {
        Column({ space: Space.md }) {
          Search({ value: this.filter, placeholder: t("筛选服务或模型") }).id('usage-filter').height(40)
            .backgroundColor($r('app.color.surface')).placeholderColor($r('app.color.text_tertiary'))
            .onChange((value) => { this.filter = value; this.visible = 30; })
          Row({ space: Space.sm }) {
            StatTile({ value: compactNumber(this.filtered().length), label: t("请求") })
            StatTile({ value: compactNumber(this.totals()[0]), label: t("输入 Token") })
            StatTile({ value: compactNumber(this.totals()[1]), label: t("输出 Token") })
          }.width('100%')
          Text(t("本机记录，不是服务商账单。缓存计入输入，推理计入输出") + (this.totals()[2] ? t("；另有 ") + this.totals()[2] + t(" 次请求未报告用量。") : '。'))
            .fontSize(Font.caption).lineHeight(18).width('100%').fontColor($r('app.color.text_tertiary'))
        }.width('100%').padding({ top: Space.sm, bottom: Space.md })
      }
      if (this.filtered().length === 0) {
        ListItem() {
          EmptyState({ icon: $r('sys.symbol.clock'), title: this.filter ? t("没有匹配的记录") : t("还没有用量记录"),
            caption: this.filter ? '' : t("向模型发送消息后，每次请求的耗时与 Token 会记录在这里。") })
        }
      } else {
        ListItem() {
          GroupCard() {
            Column() {
              ForEach(this.filtered().slice(0, this.visible), (item: RequestUsage, index: number) => {
                if (index > 0) { RowDivider() }
                this.usageRow(item)
              }, (item: RequestUsage) => item.id + item.status + item.durationMs)
            }
          }
        }
      }
      if (this.filtered().length > this.visible) {
        ListItem() {
          Button(t("显示更早的请求")).attributeModifier(Btn.textSmall).onClick(() => { this.visible += 30; })
        }.width('100%').padding({ top: Space.sm })
      }
      if (UsageLedger.error) {
        ListItem() { Banner({ text: UsageLedger.error }).margin({ top: Space.md }) }
      }
    }.width('100%').height('100%').padding({ left: Space.page, right: Space.page }).scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring).contentEndOffset(Space.xl)
  }

  @Builder
  backupTab() {
    Scroll() {
      Column() {
        SectionHeader({ title: t("备份与恢复"), caption: t("包含对话、附件、工作区文件、Skills、模板与记忆，最多 20 MB。") })
        GroupCard() {
          Column() {
            NavRow({ title: t("导出备份"), subtitle: t("存到本机，或分享到其他设备"), compId: 'export-backup',
              icon: $r('sys.symbol.square_and_arrow_down'), disabled: this.app.busy || this.busy, onTap: () => this.backup(false) })
            RowDivider()
            NavRow({ title: t("从备份导入"), subtitle: t("作为独立副本恢复，不会覆盖现有对话"), compId: 'import-backup',
              icon: $r('sys.symbol.folder_badge_plus'), disabled: this.app.busy || this.busy, onTap: () => this.backup(true) })
          }
        }
        if (this.busy) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color($r('app.color.accent'))
            Text(t("正在处理备份…")).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.margin({ top: Space.md })
        }
        Row({ space: Space.sm }) {
          SymbolGlyph($r('sys.symbol.lock')).fontSize(16).fontColor([$r('app.color.text_secondary')])
          Text(t("API 密钥和 Token 不会导出。恢复后，请重新填写密钥并启用对应服务。")).fontSize(13).lineHeight(19).layoutWeight(1)
            .fontColor($r('app.color.text_secondary'))
        }.width('100%').alignItems(VerticalAlign.Top).padding(Space.md).margin({ top: Space.md })
        .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
        if (this.error) { Banner({ text: this.error }).margin({ top: Space.md }) }
      }.width('100%').padding({ left: Space.page, right: Space.page, bottom: Space.xl })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }

  build() {
    Column() {
      Segmented({ options: [t("设置"), t("用量"), t("备份")], selected: this.currentIndex(), compIdPrefix: 'assistant-tab',
        onSelect: (index: number) => this.selectTab(index) })
        .padding({ left: Space.page, right: Space.page, top: Space.xs, bottom: Space.xs })
      Tabs({ index: this.currentIndex(), controller: this.tabs }) {
        TabContent() { this.settingsTab() }
        TabContent() { this.usageTab() }
        TabContent() { this.backupTab() }
      }.barHeight(0).layoutWeight(1).animationDuration(250)
      .onChange((index: number) => { this.tab = TABS[index]; if (index === 1) { this.records = UsageLedger.list(); } })
    }.width('100%').height('100%')
  }
}
