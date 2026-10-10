import { WebUiView } from './WebUiView';
import { LengthMetrics } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { t } from '../model/I18n';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UiCompiler, UiNode, UiPart, UiSavedState, UiValue, UiValues,
  copyUiValues, uiNodeText, uiNodeVisible, uiStepValue, uiText, uiParts, validateUiState } from '../model/InteractiveUi';
import { Btn, Radius, Space } from '../common/Theme';
import { Segmented } from '../common/Widgets';
import { MarkdownView } from './MarkdownView';
import { DataViewCard } from './DataViewCard';
import { UiSceneView } from './UiSceneView';

@Component
struct UiNodeView {
  @Prop node: UiNode;
  @Prop nodes: UiNode[];
  @Prop values: UiValues;
  @Prop interactive: boolean = false;
  @Prop ready: boolean = false;
  @Prop layoutWidth: number | string = '100%';
  onWebSave: (values: UiValues) => Promise<UiValues> = async () => { throw new Error('Web UI save handler missing'); };
  onEdit: (node: UiNode, value: UiValue, commit: boolean) => void = () => {};
  onAction: (id: string) => void = () => {};
  onCommit: (id: string) => void = () => {};
  onInvalid: (id: string, invalid: boolean) => void = () => {};
  @State private imageError: boolean = false;
  @State private rowWidth: number = 0;
  private children(): UiNode[] { return this.nodes.filter((item) => item.parent === this.node.id && uiNodeVisible(item, this.values)); }
  private childWidth(): number | string {
    return this.node.kind === 'row' && this.rowWidth >= 400 ? (this.rowWidth - 12) / 2 : '100%';
  }
  private label(): string { return uiNodeText(this.node, this.values); }
  private value(): UiValue { return this.values[this.node.bind || '']; }
  private options(): SelectOption[] { return (this.node.options || []).map((value): SelectOption => ({ value: value })); }
  private segmentedWidth(): number {
    const options = this.node.options || [];
    return options.reduce((width: number, label: string) => Math.max(width, label.length * 14 + 32), 100) * options.length;
  }
  private editText(value: string): void {
    const valid = this.node.kind !== 'number' || (value.trim().length > 0 && Number.isFinite(Number(value)));
    this.onInvalid(this.node.id, !valid);
    if (valid) { this.onEdit(this.node, this.node.kind === 'number' ? Number(value) : value, false); }
  }
  // Stable keys retain child instances; resolve their latest node from the reactive array.
  @Builder
  childrenView() {
    ForEach(this.children(), (child: UiNode) => {
      UiNodeView({ node: this.nodes.find((item: UiNode) => item.id === child.id) as UiNode, nodes: this.nodes, values: this.values, interactive: this.interactive,
        ready: this.ready, layoutWidth: this.childWidth(), onWebSave: this.onWebSave, onEdit: this.onEdit, onAction: this.onAction, onCommit: this.onCommit, onInvalid: this.onInvalid })
    }, (child: UiNode) => child.id)
  }
  build() {
    Column({ space: 6 }) {
      if (!this.node.visibleKey || this.values[this.node.visibleKey] === this.node.visibleValue) {
        if (this.node.kind === 'row') {
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(8) } }) { this.childrenView() }
            .width('100%').onAreaChange((_old: Area, area: Area) => { this.rowWidth = Number(area.width); })
        } else if (this.node.kind === 'column' || this.node.kind === 'card') {
          Column({ space: 12 }) { this.childrenView() }.width('100%').alignItems(HorizontalAlign.Start)
            .padding(this.node.kind === 'card' ? 14 : 0).borderRadius(Radius.md)
            .backgroundColor(this.node.kind === 'card' ? $r('app.color.surface_variant') : Color.Transparent)
        } else if (this.node.kind === 'text' || this.node.kind === 'heading') {
          Text(this.label()).fontSize(this.node.kind === 'heading' ? 20 : 15)
            .fontWeight(this.node.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice)
        } else if (this.node.kind === 'markdown') {
          MarkdownView({ content: this.label() })
        } else if (this.node.kind === 'divider') {
          Divider().color($r('app.color.divider'))
        } else if (this.node.kind === 'button') {
          Button(this.label()).attributeModifier(Btn.tonalSmall).enabled(this.interactive)
            .onClick(() => this.onAction(this.node.action || ''))
        } else if (this.node.kind === 'input' || this.node.kind === 'number') {
          Text(this.label()).fontSize(13).fontColor($r('app.color.text_secondary'))
          TextInput({ text: String(this.value()) }).maxLength(2000)
            .type(this.node.kind === 'number' ? InputType.Number : InputType.Normal)
            .enabled(this.interactive).accessibilityText(this.label()).onChange((value: string) => this.editText(value))
            .onEditChange((editing: boolean) => { if (!editing) { this.onCommit(this.node.action || ''); } })
        } else if (this.node.kind === 'select') {
          Text(this.label()).fontSize(13).fontColor($r('app.color.text_secondary'))
          Select(this.options()).value(String(this.value())).selected((this.node.options || []).indexOf(String(this.value())))
            .enabled(this.interactive).accessibilityText(this.label())
            .onSelect((_index: number, value: string) => this.onEdit(this.node, value, true))
        } else if (this.node.kind === 'segmented') {
          Text(this.label()).fontSize(13).fontColor($r('app.color.text_secondary'))
          Scroll() {
            Segmented({ options: this.node.options || [], selected: (this.node.options || []).indexOf(String(this.value())),
              compIdPrefix: 'ui-' + this.node.id, controlHeight: 44,
              onSelect: (index: number) => { if (this.interactive) { this.onEdit(this.node, (this.node.options || [])[index], true); } } })
              .width(this.segmentedWidth()).enabled(this.interactive)
          }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        } else if (this.node.kind === 'stepper') {
          Text(this.label()).fontSize(13).fontColor($r('app.color.text_secondary'))
          Row({ space: 12 }) {
            Button('−').attributeModifier(Btn.tonalSmall).width(44).height(44)
              .id('ui-' + this.node.id + '-decrease').accessibilityText(this.label() + ' −')
              .enabled(this.interactive && Number(this.value()) > (this.node.min as number))
              .onClick(() => this.onEdit(this.node, uiStepValue(this.node, this.values, -1), true))
            Text(String(this.value())).id('ui-' + this.node.id + '-value').fontSize(18).fontWeight(FontWeight.Medium)
              .layoutWeight(1).textAlign(TextAlign.Center).fontColor($r('app.color.text_primary'))
            Button('+').attributeModifier(Btn.tonalSmall).width(44).height(44)
              .id('ui-' + this.node.id + '-increase').accessibilityText(this.label() + ' +')
              .enabled(this.interactive && Number(this.value()) < (this.node.max as number))
              .onClick(() => this.onEdit(this.node, uiStepValue(this.node, this.values, 1), true))
          }.width('100%')
        } else if (this.node.kind === 'checkbox') {
          Row({ space: 8 }) {
            Checkbox({ name: this.node.id }).select(this.value() === true).enabled(this.interactive)
              .id('ui-' + this.node.id).accessibilityText(this.label()).selectedColor($r('app.color.accent'))
              .onChange((value: boolean) => this.onEdit(this.node, value, true))
            Text(this.label()).fontSize(15).layoutWeight(1).fontColor($r('app.color.text_primary'))
              .decoration({ type: this.value() === true ? TextDecorationType.LineThrough : TextDecorationType.None })
          }.width('100%').constraintSize({ minHeight: 44 })
        } else if (this.node.kind === 'toggle') {
          Row({ space: 12 }) {
            Text(this.label()).fontSize(15).layoutWeight(1).fontColor($r('app.color.text_primary'))
            Toggle({ type: ToggleType.Switch, isOn: this.value() === true }).enabled(this.interactive)
              .accessibilityText(this.label()).onChange((value: boolean) => this.onEdit(this.node, value, true))
          }.width('100%')
        } else if (this.node.kind === 'slider') {
          Text(this.label() + ': ' + String(this.value())).fontSize(13).fontColor($r('app.color.text_secondary'))
          Slider({ value: Number(this.value()), min: this.node.min, max: this.node.max, step: this.node.step || 1 })
            .enabled(this.interactive).accessibilityText(this.label())
            .onChange((value: number, mode: SliderChangeMode) => this.onEdit(this.node, value, mode === SliderChangeMode.End || mode === SliderChangeMode.Click))
        } else if (this.node.kind === 'progress') {
          Text(this.label()).fontSize(13).fontColor($r('app.color.text_secondary'))
          Progress({ value: Number(this.value()) - (this.node.min || 0), total: (this.node.max || 100) - (this.node.min || 0) })
            .width('100%').color($r('app.color.accent')).accessibilityText(this.label() + ': ' + this.value())
        } else if (this.node.kind === 'data') {
          DataViewCard({ content: this.node.bind ? String(this.value()) : this.node.data || '' })
        } else if (this.node.kind === 'scene') {
          UiSceneView({ content: this.node.bind ? String(this.value()) : this.node.data || '', interactive: this.interactive, onAction: this.onAction })
        } else if (this.node.kind === 'web') {
          if (this.ready) {
            WebUiView({ content: this.node.data || '', values: this.values, interactive: this.interactive, onSave: this.onWebSave })
          }
        } else if (this.node.kind === 'image') {
          Image(this.node.source).width('100%').height(220).objectFit(ImageFit.Contain).accessibilityText(this.label())
            .onError(() => { this.imageError = true; })
          if (this.imageError) { Text(t('图片加载失败')).fontColor($r('app.color.danger')) }
          Text(this.label()).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }
    }.width(this.layoutWidth)
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
struct UiSurface {
  @Prop @Watch('refresh') source: string;
  @Prop @Watch('refresh') closed: boolean;
  @Prop @Watch('refresh') streaming: boolean;
  @Prop available: boolean = false;
  surfaceKey: string = '';
  saved: UiSavedState[] = [];
  onInteract: (key: string, values: UiValues, action: string) => Promise<UiValues> = async () => { throw new Error('Interactive UI handler is not connected'); };
  @State private nodes: UiNode[] = [];
  @State private values: UiValues = {};
  @State private title: string = '';
  @State private complete: boolean = false;
  @State private busy: boolean = false;
  @State private dirty: boolean = false;
  @State private error: string = '';
  @State private invalid: string[] = [];
  private compiler: UiCompiler = new UiCompiler();
  private initialized: boolean = false;
  private failed: boolean = false;
  private mounted: boolean = false;
  private commitTimer: number = -1;
  aboutToAppear(): void { this.mounted = true; this.refresh(); }
  aboutToDisappear(): void { this.mounted = false; clearTimeout(this.commitTimer); }
  private report(error: Error): void {
    this.error = error.message;
    hilog.error(0x0000, 'TinybotUI', 'surface=%{public}s chars=%{public}d closed=%{public}s streaming=%{public}s nodes=%{public}d error=%{public}s',
      this.surfaceKey, this.source.length, String(this.closed), String(this.streaming), this.nodes.length, error.message);
  }
  private refresh(): void {
    if (this.failed) { return; }
    try {
      const document = this.compiler.update(this.source, this.closed || !this.streaming);
      if (!this.closed && !this.streaming) { throw new Error(t('界面生成未完成，无法交互。')); }
      this.title = document.title; this.nodes = document.nodes.slice(); this.complete = document.complete && this.closed;
      if (!this.initialized && document.title) {
        const saved = this.saved.find((item) => item.key === this.surfaceKey);
        this.values = copyUiValues(saved ? saved.values : document.initial); this.initialized = true;
      }
      if (this.complete) { validateUiState(document, this.values); }
    } catch (error) { this.failed = true; this.complete = false; this.report(error as Error); }
  }
  private async saveWeb(values: UiValues): Promise<UiValues> {
    if (!this.complete || !this.available || this.busy) { throw new Error(t('交互界面已不可用。')); }
    validateUiState(this.compiler.document, values); this.busy = true; this.error = '';
    try {
      const saved = await this.onInteract(this.surfaceKey, copyUiValues(values), '');
      if (this.mounted) { this.values = saved; this.dirty = false; }
      return saved;
    } catch (error) { if (this.mounted) { this.report(error as Error); } throw error as Error; }
    finally { if (this.mounted) { this.busy = false; } }
  }
  private edit(node: UiNode, value: UiValue, commit: boolean): void {
    if (!this.complete || this.busy || !this.available || !node.bind) { return; }
    const next = copyUiValues(this.values); next[node.bind] = value;
    this.values = next; this.dirty = true;
    if (commit) { this.interact(node.action || ''); }
  }
  private schedule(action: string): void {
    clearTimeout(this.commitTimer);
    if (this.dirty && !this.busy && this.available) { this.commitTimer = setTimeout(() => { this.interact(action); }, 180); }
  }
  private async interact(action: string): Promise<void> {
    clearTimeout(this.commitTimer);
    if (!this.complete || this.busy || !this.available || this.invalid.length || (!action && !this.dirty)) { return; }
    this.busy = true; this.error = '';
    try {
      validateUiState(this.compiler.document, this.values);
      const definition = this.compiler.document.actions.find((item) => item.id === action);
      if (definition?.kind === 'copy') {
        try {
          await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, uiText(definition.text || '', this.values)));
        } catch (_) { throw new Error(t('复制失败，请长按文本复制。')); }
        this.getUIContext().getPromptAction().showToast({ message: t('已复制') });
        return;
      }
      const saved = await this.onInteract(this.surfaceKey, copyUiValues(this.values), action);
      if (this.mounted) { this.values = saved; this.dirty = false; }
    } catch (error) { if (this.mounted) { this.report(error as Error); } }
    finally { if (this.mounted) { this.busy = false; } }
  }
  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.title || t('交互界面')).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1).fontColor($r('app.color.text_primary'))
        if (this.busy || (!this.complete && !this.failed)) { LoadingProgress().width(18).height(18) }
      }.width('100%')
      ForEach(this.nodes.filter((node: UiNode) => !node.parent && uiNodeVisible(node, this.values)), (node: UiNode) => {
        UiNodeView({ node: this.nodes.find((item: UiNode) => item.id === node.id) as UiNode, nodes: this.nodes, values: this.values, interactive: this.complete && this.available && !this.busy,
          ready: this.complete && !this.streaming, onWebSave: (values: UiValues) => this.saveWeb(values),
          onEdit: (item: UiNode, value: UiValue, commit: boolean) => this.edit(item, value, commit),
          onAction: (id: string) => { this.interact(id); },
          onCommit: (id: string) => this.schedule(id),
          onInvalid: (id: string, invalid: boolean) => { this.invalid = this.invalid.filter((key) => key !== id).concat(invalid ? [id] : []); } })
      }, (node: UiNode) => node.id)
      if (this.invalid.length > 0) { Text(t('请输入有效数字。')).fontSize(13).fontColor($r('app.color.danger')) }
      if (this.error) { Text(this.error).fontSize(13).fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice) }
      if (this.dirty && this.complete) {
        Button(t('保存输入')).attributeModifier(Btn.textSmall).enabled(this.available && !this.busy && this.invalid.length === 0)
          .onClick(() => { this.interact(''); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(Radius.md)
    .backgroundColor($r('app.color.surface')).border({ width: 1, color: $r('app.color.divider') })
  }
}

@Component
export struct InteractiveAnswer {
  @Prop selectable: boolean = true;
  @Prop validation: string = '';
  @Prop @Watch('refresh') content: string = '';
  @Prop @Watch('refresh') streaming: boolean = false;
  @Prop available: boolean = false;
  step: number = 0;
  saved: UiSavedState[] = [];
  onInteract: (key: string, values: UiValues, action: string) => Promise<UiValues> = async () => { throw new Error('Interactive UI handler is not connected'); };
  @State private parts: UiPart[] = [];
  aboutToAppear(): void { this.refresh(); }
  private refresh(): void { this.parts = uiParts(this.content, this.streaming); }
  build() {
    Column({ space: Space.md }) {
      // ForEach retains keyed item closures. Read the current state by index so reused children receive new chunks.
      ForEach(this.parts, (part: UiPart, index: number) => {
        if (part.kind === 'text') { MarkdownView({ content: this.parts[index].content, streaming: this.streaming, selectable: this.selectable }) }
        else if (this.validation && !this.streaming) {
          Text(this.validation === 'pending' ? t('正在检查交互内容…') : t('交互内容检查未通过。'))
            .fontSize(13).fontColor($r('app.color.text_secondary'))
        } else {
          UiSurface({ source: this.parts[index].content, closed: this.parts[index].closed, streaming: this.streaming, available: this.available,
            surfaceKey: this.step + ':' + part.key, saved: this.saved, onInteract: this.onInteract })
        }
      }, (part: UiPart) => part.kind + '-' + part.key)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
