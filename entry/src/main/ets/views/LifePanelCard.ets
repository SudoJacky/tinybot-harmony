import { panelErrorText } from '../model/PanelPresentation';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Radius } from '../common/Theme';
import { t, getLocale } from '../model/I18n';
import { MiniAppStorage } from '../model/MiniApp';
import { WebUiPanelContext } from '../model/WebUi';
import { WebUiView } from './WebUiView';
import { IconButton } from '../common/Widgets';
import { PanelNode, PanelRecord, PanelItem, PanelBinding, panelValue, panelText, panelNumber, panelItems, panelPoints } from '../model/LifePanel';

function toneColor(tone?: string): Resource {
  if (tone === 'positive') { return $r('app.color.avatar_1_fg'); }
  if (tone === 'warning') { return $r('app.color.avatar_3_fg'); }
  if (tone === 'negative') { return $r('app.color.avatar_5_fg'); }
  if (tone === 'neutral') { return $r('app.color.text_primary'); }
  return $r('app.color.accent');
}
@Component
struct PanelSparkline {
  @Prop @Watch('draw') points: number[] = [];
  @Prop @Watch('draw') tone: string = 'accent';
  @StorageProp('tinybot.appearance.dark') @Watch('draw') private dark: boolean = false;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private draw(): void {
    if (!this.ready) { return; }
    const width = this.canvas.width, height = this.canvas.height;
    this.canvas.clearRect(0, 0, width, height);
    const min = Math.min(...this.points), max = Math.max(...this.points), range = max - min || 1;
    const color = this.getUIContext().getHostContext()!.resourceManager.getColorSync(toneColor(this.tone).id) >>> 0;
    this.canvas.strokeStyle = 'rgb(' + ((color >> 16) & 255) + ',' + ((color >> 8) & 255) + ',' + (color & 255) + ')';
    this.canvas.lineWidth = 2.5; this.canvas.lineJoin = 'round';
    this.canvas.beginPath();
    this.points.forEach((value: number, index: number) => {
      const x = 3 + index / (this.points.length - 1) * (width - 6), y = height - 4 - (value - min) / range * (height - 8);
      if (index === 0) { this.canvas.moveTo(x, y); } else { this.canvas.lineTo(x, y); }
    });
    this.canvas.stroke();
  }
  build() {
    Canvas(this.canvas).width('100%').height(72).onReady(() => { this.ready = true; this.draw(); })
      .onAreaChange(() => this.draw())
      .accessibilityText(t('趋势：{0}', [this.points.join(', ')]))
  }
}
@Component
struct PanelComponent {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop panel: PanelRecord;
  @Prop node: PanelNode;
  @Prop interactive: boolean = true;
  @Prop expanded: boolean = false;
  @Prop compact: boolean = false;
  onToggle: (node: string, item: string, done: boolean) => void = () => {};
  onRefresh: () => void = () => {};
  @State private revealed: boolean = false;
  private value(binding: PanelBinding): Object | null { return panelValue(binding, this.panel.data, this.panel.user); }
  private label(): string { return this.node.text ? panelText(this.value(this.node.text)) : ''; }
  private children(): PanelNode[] { return this.panel.definition.nodes.filter((node: PanelNode) => node.parent === this.node.id); }
  private items(): PanelItem[] { return panelItems(this.value(this.node.items!)); }
  private checked(item: PanelItem): boolean {
    const key = this.node.id + ':' + item.id;
    return Object.keys(this.panel.user).includes(key) ? this.panel.user[key] : item.done === true;
  }
  private completed(): number { return this.items().filter((item: PanelItem) => this.checked(item)).length; }
  private metric(): string { return panelNumber(this.value(this.node.value!)).toFixed(this.node.decimals === undefined ? 0 : this.node.decimals) + (this.node.suffix || ''); }
  @Builder private caption() {
    if (this.node.text) {
      Text(this.label()).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(2)
    }
  }
  build() {
    if (this.node.kind === 'Row') {
      Row({ space: 12 }) {
        ForEach(this.children(), (child: PanelNode) => {
          PanelComponent({ panel: this.panel, node: child, interactive: this.interactive, expanded: this.expanded, compact: this.compact, onToggle: this.onToggle, onRefresh: this.onRefresh }).layoutWeight(1)
        }, (child: PanelNode) => child.id)
      }.width('100%').alignItems(VerticalAlign.Top)
    } else if (this.node.kind === 'Column') {
      Column({ space: 10 }) {
        ForEach(this.children(), (child: PanelNode) => {
          PanelComponent({ panel: this.panel, node: child, interactive: this.interactive, expanded: this.expanded, compact: this.compact, onToggle: this.onToggle, onRefresh: this.onRefresh })
        }, (child: PanelNode) => child.id)
      }.width('100%').alignItems(HorizontalAlign.Start)
    } else if (this.node.kind === 'Text') {
      Text(this.label()).fontFamily(this.appearance.fontFamily).fontSize(14).fontColor(toneColor(this.node.tone)).width('100%')
    } else if (this.node.kind === 'Metric') {
      Column({ space: 4 }) {
        this.caption()
        if (this.node.private) {
          Button(this.revealed ? this.metric() : '••••').type(ButtonType.Normal).backgroundColor(Color.Transparent)
            .fontSize(28).fontWeight(FontWeight.Medium).fontColor(toneColor(this.node.tone)).padding(0)
            .accessibilityText(this.revealed ? t('隐藏数值') : t('显示数值')).onClick(() => { this.revealed = !this.revealed; })
        } else {
          Text(this.metric()).fontFamily(this.appearance.fontFamily).fontSize(28).fontWeight(FontWeight.Medium)
            .fontColor(toneColor(this.node.tone)).maxLines(1).minFontSize(18).maxFontSize(28)
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    } else if (this.node.kind === 'Progress') {
      Column({ space: 8 }) {
        this.caption()
        Text(panelNumber(this.value(this.node.value!)).toString() + ' / ' + panelNumber(this.value(this.node.max!)).toString())
          .fontSize(18).fontColor(toneColor(this.node.tone))
        Progress({ value: panelNumber(this.value(this.node.value!)), total: panelNumber(this.value(this.node.max!)), type: ProgressType.Linear })
          .color(toneColor(this.node.tone)).width('100%').style({ strokeWidth: 6 })
      }.width('100%').alignItems(HorizontalAlign.Start)
    } else if (this.node.kind === 'Sparkline') {
      Column({ space: 4 }) {
        this.caption()
        PanelSparkline({ points: panelPoints(this.value(this.node.value!)), tone: this.node.tone || 'accent' })
      }.width('100%')
    } else if (this.node.kind === 'ItemList' || this.node.kind === 'Checklist') {
      Column({ space: 8 }) {
        this.caption()
        if (this.node.kind === 'Checklist') {
          Row() {
            Text(t('已完成 {0}/{1}', [this.completed(), this.items().length])).fontSize(12).fontColor(toneColor(this.node.tone))
          }.width('100%')
          Progress({ value: this.completed(), total: Math.max(1, this.items().length), type: ProgressType.Linear })
            .color(toneColor(this.node.tone)).width('100%').style({ strokeWidth: 4 })
        }
        ForEach(this.items().slice(0, this.compact ? 0 : this.expanded ? 100 : Math.min(this.node.limit || 3, 3)), (item: PanelItem) => {
          Row({ space: 8 }) {
            if (this.node.kind === 'Checklist') {
              Checkbox({ name: item.id, group: this.node.id }).select(this.checked(item)).enabled(this.interactive)
                .selectedColor(toneColor(this.node.tone)).width(22).height(22).margin(0)
                .accessibilityText(item.label).onChange((done: boolean) => { if (done !== this.checked(item)) { this.onToggle(this.node.id, item.id, done); } })
            }
            Text(item.label).fontFamily(this.appearance.fontFamily).fontSize(14).layoutWeight(1)
              .fontColor(this.node.kind === 'Checklist' && this.checked(item) ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
              .decoration({ type: this.node.kind === 'Checklist' && this.checked(item) ? TextDecorationType.LineThrough : TextDecorationType.None }).maxLines(2)
            if (item.value !== undefined) { Text(item.value).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1) }
          }.width('100%').constraintSize({ minHeight: 32 })
        }, (item: PanelItem) => item.id)
        if (!this.expanded && this.items().length > (this.compact ? 0 : Math.min(this.node.limit || 3, 3))) {
          Text(t('还有 {0} 项', [this.items().length - (this.compact ? 0 : Math.min(this.node.limit || 3, 3))])).fontSize(12).fontColor($r('app.color.text_tertiary'))
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    } else if (this.node.kind === 'ActionButton' && this.interactive) {
      Button(this.label()).attributeModifier(Btn.tonal).enabled(this.interactive).onClick(this.onRefresh)
    }
  }
}
@Component
export struct LifePanelCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop panel: PanelRecord;
  @Prop busy: boolean = false;
  @Prop interactive: boolean = true;
  @Prop onBoard: boolean = false;
  @Prop cardSize: string = '';
  @Prop detail: boolean = false;
  @Prop timestamp: string = '';
  @Prop editing: boolean = false;
  @Prop viewHeight: number = 320;
  storage?: MiniAppStorage;
  onRun: () => Promise<void> = async () => {};
  onMoveStart: () => void = () => {};
  onMoveUpdate: (event: GestureEvent) => void = () => {};
  onMoveEnd: (event: GestureEvent) => void = () => {};
  onMoveCancel: () => void = () => {};
  onResize: (event: GestureEvent, finished: boolean) => void = () => {};
  private context(): WebUiPanelContext {
    return { data: this.panel.data, title: this.panel.definition.title, status: this.busy ? 'running' : this.panel.error ? 'failed' : 'ready',
      canRefresh: !!this.panel.definition.source && !this.panel.archived, locale: getLocale() };
  }
  onOpen: () => void = () => {};
  onRefresh: () => void = () => {};
  onToggle: (node: string, item: string, done: boolean) => void = () => {};
  onSize: (size: string) => void = () => {};
  onArchive: () => void = () => {};
  onConnect: () => void = () => {};
  onPin: () => void = () => {};
  onUnpin: () => void = () => {};
  onTask: () => void = () => {};
  onEdit: () => void = () => {};
  @Builder private menu() {
    Menu() {
      MenuItem({ content: t('用 AI 修改卡片') }).onClick(this.onEdit)
      MenuItem({ content: t('固定到看板') }).onClick(this.onPin)
      if (this.onBoard) { MenuItem({ content: t('从此看板移除') }).onClick(this.onUnpin) }
      if (this.panel.definition.source) { MenuItem({ content: t('刷新任务与记录') }).onClick(this.onTask) }
      if (this.panel.definition.source?.auth) { MenuItem({ content: t('API 连接') }).onClick(this.onConnect) }
      MenuItemGroup({ header: t('卡片尺寸') }) {
        ForEach(['S', 'M', 'L'], (size: string) => {
          MenuItem({ content: size }).selected((this.cardSize || this.panel.definition.size) === size).selectIcon(true).onClick(() => this.onSize(size))
        })
      }
      MenuItem({ content: this.panel.archived ? t('恢复') : t('移除') }).onClick(this.onArchive)
    }
  }
  build() {
    Column({ space: this.panel.definition.view ? 0 : 10 }) {
      Row({ space: 6 }) {
        if (this.editing) {
          Text('⠿').fontSize(24).fontColor($r('app.color.text_secondary')).width(40).height(44).textAlign(TextAlign.Center)
            .accessibilityText(t('拖动卡片')).id('panel-drag-' + this.panel.id)
            .gesture(PanGesture().onActionStart(this.onMoveStart).onActionUpdate(this.onMoveUpdate).onActionEnd(this.onMoveEnd).onActionCancel(this.onMoveCancel))
        }
        Button({ type: ButtonType.Normal }) {
          Text(this.panel.definition.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').textAlign(TextAlign.Start)
        }.backgroundColor(Color.Transparent).padding(0).layoutWeight(1).constraintSize({ minHeight: 40 })
          .onClick(() => { if (!this.editing) { this.onOpen(); } }).accessibilityText(t('打开卡片「{0}」', [this.panel.definition.title]))
        if (this.interactive && !this.editing) {
          Button({ type: ButtonType.Normal }) { Text('⋯').fontSize(24).fontColor($r('app.color.text_secondary')) }
            .backgroundColor(Color.Transparent).borderRadius(8).width(36).height(40).padding(0)
            .bindMenu(this.menu()).accessibilityText(t('卡片选项'))
        }
      }.width('100%').padding(this.panel.definition.view ? { left: 12, right: 12, top: 4, bottom: 4 } : 0)
      if (this.panel.error) {
        Text(panelErrorText(this.panel.error)).fontSize(12).fontColor($r('app.color.danger')).maxLines(this.detail ? 8 : 3)
          .width('100%').accessibilityText(t('刷新失败：{0}', [panelErrorText(this.panel.error)]))
          .padding(this.panel.definition.view ? { left: 12, right: 12, bottom: 8 } : 0)
      }
      if (this.panel.definition.source && !this.panel.refreshedAt) {
        Text(t('初始数据 · 尚未从数据源更新')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          .padding(this.panel.definition.view ? { left: 12, right: 12, bottom: 8 } : 0)
      }
      if (this.panel.paused && this.panel.definition.source) {
        Text(t('自动更新已暂停')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          .padding(this.panel.definition.view ? { left: 12, right: 12, bottom: 8 } : 0)
      }
      if (this.panel.definition.view) {
        if (this.storage) {
          WebUiView({ content: JSON.stringify(this.panel.definition.view), storage: this.storage, panelContext: this.context(),
            interactive: this.interactive && !this.panel.archived && !this.editing, viewportHeight: this.viewHeight, onPanelRefresh: this.onRun })
        } else {
          Button(t('打开交互卡片')).attributeModifier(Btn.tonal).onClick(this.onOpen)
            .margin({ left: 12, right: 12, top: 8, bottom: 8 })
        }
      } else {
      Column({ space: 10 }) {
        ForEach(this.panel.definition.nodes.filter((node: PanelNode) => !node.parent), (node: PanelNode) => {
          PanelComponent({ panel: this.panel, node: node, interactive: this.interactive && !this.busy && !this.panel.archived,
            expanded: this.detail || (this.cardSize || this.panel.definition.size) === 'L', compact: !this.detail && (this.cardSize || this.panel.definition.size) === 'S',
            onToggle: this.onToggle, onRefresh: this.onRefresh })
        }, (node: PanelNode) => node.id)
      }.width('100%').alignItems(HorizontalAlign.Start)
      }
      Row({ space: 4 }) {
        Text(this.timestamp).fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.panel.definition.view && !this.detail && !this.editing && this.interactive) {
          IconButton({ icon: $r('sys.symbol.arrow_up_left_and_arrow_down_right'), label: t('展开卡片'), diameter: 40, iconSize: 18, onTap: this.onOpen })
        }
        if (this.interactive && this.panel.definition.source && !this.panel.archived) {
          Button(this.busy ? t('刷新中') : t('刷新')).type(ButtonType.Normal).fontSize(11).padding({ left: 4, right: 4 })
            .height(40).constraintSize({ minWidth: 40 }).backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary')).enabled(this.interactive && !this.busy && !this.editing).onClick(this.onRefresh)
        }
      }.width('100%').padding(this.panel.definition.view ? { left: 12, right: 12, top: 4, bottom: 4 } : 0)
      if (this.editing) {
        Row() {
          Text(t('拖动调整尺寸')).fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Text('↘').fontSize(24).width(44).height(44).textAlign(TextAlign.Center).id('panel-resize-' + this.panel.id)
            .accessibilityText(t('调整卡片尺寸')).gesture(PanGesture()
              .onActionUpdate((event: GestureEvent) => this.onResize(event, false))
              .onActionEnd((event: GestureEvent) => this.onResize(event, true)).onActionCancel(this.onMoveCancel))
        }.width('100%').padding(this.panel.definition.view ? { left: 12, right: 12 } : 0)
      }
    }.width('100%').padding(this.panel.definition.view ? 0 : 14).backgroundColor($r('app.color.surface'))
      .borderRadius(Radius.lg).border({ width: 1, color: $r('app.color.divider') })
      .clip(!!this.panel.definition.view)
  }
}
