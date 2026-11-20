import { Diagnostics } from '../model/Diagnostics';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { AnimatedIcon } from '../common/AnimatedIcon';
import { PreviewFullscreenMotion, previewFullscreenMotion } from '../common/FullscreenTransition';
import { t } from '../model/I18n';
import { highlightCodeBlocks } from '../model/CodeHighlight';
import { MarkdownSpan } from '../model/Markdown';
import { PublishedPreview, publishedPreviewSource } from '../model/PublishedPreview';
import { UiSavedState, UiValues } from '../model/InteractiveUi';
import { Attachments } from '../services/Attachments';
import { Btn, codeTokenColor, Font, Motion, Radius, Space } from '../common/Theme';
import { UiPresentation } from '../model/UiPresentation';
import { PreviewFullscreen } from './PreviewFullscreen';
import { PreviewSurface, PreviewSurfaceOptions } from './PreviewSurface';
import { IconButton } from '../common/Widgets';

const MODE_TARGET: number = 44;
const MODE_TRACK_RADIUS: number = 17;
const MODE_INSET: number = 3;

@Component
export struct PublishedPreviewCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.freeWindow') private desktop: boolean = false;
  presentation?: UiPresentation;
  @Prop @Watch('revisionChanged') preview: PublishedPreview;
  @Prop @Watch('surfaceChanged') available: boolean = false;
  @Prop inspectable: boolean = false;
  @Prop inspected: boolean = false;
  onInspect: () => void = () => {};
  @Prop inline: boolean = false;
  saved: UiSavedState[] = [];
  onInteract: (key: string, values: UiValues, action: string) => Promise<UiValues> = async () => { throw new Error('Preview interaction handler missing'); };
  @State private expanded: boolean = false;
  @State private imageError: boolean = false;
  @State private fullscreen: boolean = false;
  @State private fullscreenClosing: boolean = false;
  private fullscreenMotion?: PreviewFullscreenMotion;
  @State private inlineHeight: number = 0;
  @State private showCode: boolean = false;
  @State private hoveredMode: boolean | undefined = undefined;
  @State private codeBlocks: MarkdownSpan[][] = [];
  @State private codeError: boolean = false;
  private highlightedContent?: string;
  private superseded: boolean = false;
  private surface: PreviewSurface = new PreviewSurface();
  aboutToAppear(): void { this.superseded = this.preview.superseded; this.expanded = !this.superseded; this.surfaceChanged(); }
  aboutToDisappear(): void { this.surface.dispose(); }
  private surfaceChanged(): void {
    const options = new PreviewSurfaceOptions(this.preview);
    options.saved = this.saved; options.presentation = this.presentation; options.available = this.available;
    options.frameless = this.inline; options.onInteract = this.onInteract;
    this.surface.setOptions(options);
  }
  private openFullscreen(): void {
    if (this.fullscreen || this.fullscreenClosing) { return; }
    this.fullscreenMotion = previewFullscreenMotion(this.getUIContext(), 'preview-card-' + this.preview.id,
      this.appearance.effectStrength > 0);
    this.surface.enterFullscreen(); this.fullscreen = true;
  }
  private closeFullscreen(): void {
    if (this.fullscreen) { this.fullscreenClosing = true; }
  }
  private fullscreenDidClose(): void {
    this.surface.exitFullscreen();
    this.fullscreenClosing = false;
  }
  private revisionChanged(): void {
    if (this.preview.superseded && !this.superseded) { this.expanded = false; }
    this.superseded = this.preview.superseded;
    this.surfaceChanged();
    if (this.showCode) { this.loadCode(); }
  }
  private loadCode(): void {
    if (this.highlightedContent === this.preview.content) { return; }
    this.highlightedContent = this.preview.content;
    try {
      const source = publishedPreviewSource(this.preview);
      this.codeBlocks = highlightCodeBlocks(source.text, source.language);
      this.codeError = false;
    } catch (error) {
      this.codeBlocks = [];
      this.codeError = true;
      Diagnostics.log('error', 'preview', 'failed', { previewId: this.preview.id }, error as Error);
    }
  }
  private selectMode(code: boolean): void {
    if (this.showCode === code) { return; }
    if (code) { this.loadCode(); }
    this.showCode = code;
  }
  private thumbnailSize(): ImageSourceSize {
    const screenshot = this.preview.screenshot;
    if (!screenshot) { throw new Error('Preview thumbnail requires a screenshot'); }
    const scale = Math.min(264 / screenshot.width, 192 / screenshot.height);
    return { width: Math.max(1, Math.round(screenshot.width * scale)), height: Math.max(1, Math.round(screenshot.height * scale)) };
  }
  @Builder
  fullscreenView() {
    PreviewFullscreen({ title: this.preview.title, surface: this.surface, motion: this.fullscreenMotion,
      closing: this.fullscreenClosing, onClose: () => this.closeFullscreen(), onClosed: () => { this.fullscreen = false; } })
  }
  @Builder
  private modeButton(code: boolean) {
    Button({ type: ButtonType.Normal }) {
      AnimatedIcon({ iconName: code ? 'code' : 'preview', selected: this.showCode === code, iconSize: 21,
        interacting: this.hoveredMode === code && (!code || this.inlineHeight > 0),
        tint: this.showCode === code ? this.appearance.accent : $r('app.color.text_secondary') })
    }.id((code ? 'preview-mode-code-' : 'preview-mode-live-') + this.preview.id)
      .width(MODE_TARGET).height(MODE_TARGET).padding(0).borderRadius(MODE_TARGET / 2).backgroundColor(Color.Transparent)
      .accessibilityText(code ? t('代码') : t('预览')).accessibilitySelected(this.showCode === code)
      .bindTips(code ? t('代码') : t('预览'), { appearingTime: 550 })
      .enabled(!code || this.inlineHeight > 0)
      .hoverEffect(!code || this.inlineHeight > 0 ? HoverEffect.Highlight : HoverEffect.None)
      .clickEffect((!code || this.inlineHeight > 0) && this.appearance.effectStrength > 0 ? Motion.press : null)
      .onHover((hovered: boolean) => {
        if (hovered) { this.hoveredMode = code; }
        else if (this.hoveredMode === code) { this.hoveredMode = undefined; }
      })
      .onClick(() => this.selectMode(code))
  }

  @Builder
  private previewModeControl() {
    Stack() {
      Row().width(MODE_TARGET * 2).height(MODE_TRACK_RADIUS * 2).borderRadius(MODE_TRACK_RADIUS).backgroundColor($r('app.color.divider'))
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Divider().vertical(true).height(14).color($r('app.color.surface_variant'))
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Row() {
        Row().width(MODE_TARGET - MODE_INSET * 2).height((MODE_TRACK_RADIUS - MODE_INSET) * 2)
          .borderRadius(MODE_TRACK_RADIUS - MODE_INSET).backgroundColor($r('app.color.surface'))
          .translate({ x: this.showCode ? 0 : MODE_TARGET })
          .animation({ duration: this.appearance.effectStrength > 0 ? Motion.fast : 0, curve: Motion.standard })
      }.width(MODE_TARGET * 2).padding({ left: MODE_INSET }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Row() {
        this.modeButton(true)
        this.modeButton(false)
      }
    }.width(MODE_TARGET * 2).height(MODE_TARGET)
  }

  @Builder
  private previewToolbar() {
    Row() {
      this.previewModeControl()
      Blank()
      if (this.desktop && this.inspectable) {
        IconButton({ animatedIcon: 'dockRight', label: t('在侧栏打开预览'),
          compId: 'dock-preview-' + this.preview.id, diameter: 40, iconSize: 17,
          fill: $r('app.color.surface_variant'), tint: $r('app.color.text_secondary'), onTap: this.onInspect })
      }
      Button({ type: ButtonType.Normal }) {
        Row({ space: Space.xs }) {
          SymbolGlyph($r('sys.symbol.full_screen')).fontSize(16).fontColor([$r('app.color.text_secondary')])
            .rotate({ angle: 90 })
          Text(t('全屏')).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_secondary'))
        }
      }.id('fullscreen-preview-' + this.preview.id).height(44).padding({ left: 6, right: 6 })
        .backgroundColor(Color.Transparent).accessibilityText(t('全屏预览'))
        .hoverEffect(this.fullscreenClosing ? HoverEffect.None : HoverEffect.Highlight)
        .clickEffect(!this.fullscreenClosing && this.appearance.effectStrength > 0 ? Motion.press : null)
        .enabled(!this.fullscreenClosing).onClick(() => this.openFullscreen())
    }.width('100%').padding({ left: Space.sm, right: Space.sm }).backgroundColor($r('app.color.surface_variant'))
  }

  @Builder
  private codeView() {
    List() {
      if (this.codeError) {
        ListItem() {
          Text(t('无法读取预览源代码。')).fontSize(Font.small).fontColor($r('app.color.danger'))
            .fontFamily(this.appearance.fontFamily).width('100%')
        }
      } else {
        Repeat<MarkdownSpan[]>(this.codeBlocks)
          .each((block: RepeatItem<MarkdownSpan[]>) => {
            ListItem() {
              Text() {
                ForEach(block.item, (span: MarkdownSpan) => {
                  Span(span.text).fontColor(codeTokenColor(span.kind))
                })
              }.width('100%').constraintSize({ minHeight: 20 }).fontSize(13).lineHeight(20).fontFamily('monospace')
                .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            }
          })
          .key((_block: MarkdownSpan[], index: number) => String(index))
          .virtualScroll()
      }
    }.id('preview-code-' + this.preview.id).position({ x: 0, y: 0 }).width('100%').height(this.inlineHeight)
      .padding({ left: Space.md, right: Space.md }).contentStartOffset(Space.md).contentEndOffset(Space.md)
      .cachedCount(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .backgroundColor($r('app.color.surface'))
  }

  build() {
    Column({ space: Space.sm }) {
      if (this.inspected || (this.inspectable && !this.inline && !this.expanded)) {
        Button(this.inspected ? t('查看预览') : t('打开预览')).attributeModifier(Btn.textSmall)
          .id('inspect-preview-' + this.preview.id).onClick(this.onInspect)
      }
      if (!this.inline && (this.preview.superseded || !this.expanded)) {
        Row({ space: Space.md }) {
          if (this.preview.screenshot && !this.imageError) {
            Image('file://' + Attachments.path(this.preview.screenshot.image)).width(88).height(64).objectFit(ImageFit.Contain)
              .sourceSize(this.thumbnailSize()).borderRadius(Radius.sm)
              .accessibilityText(this.preview.title).onError((error) => {
                this.imageError = true;
                Diagnostics.log('error', 'preview', 'thumbnail_failed', { previewId: this.preview.id }, error.message);
              })
          }
          Column({ space: 4 }) {
            Text(this.preview.title).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text(this.preview.superseded ? t('历史版本') : this.preview.path).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
            if (this.imageError) { Text(t('预览截图加载失败')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.danger')) }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button(this.expanded ? t('收起预览') : t('展开预览')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
            .id('preview-toggle-' + this.preview.id).onClick(() => { this.expanded = !this.expanded; })
        }.width('100%').padding(12).borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
      }
      if ((this.inline || this.expanded) && !this.inspected) {
        Column() {
          Column() {
            this.previewToolbar()
            Stack({ alignContent: Alignment.TopStart }) {
              // Keep the live page mounted while code covers its measured viewport.
              NodeContainer(this.surface.inlineMount).width('100%')
                .height(this.fullscreen || this.fullscreenClosing || this.showCode ? this.inlineHeight : undefined)
                .opacity(this.showCode ? 0 : 1)
                .hitTestBehavior(this.showCode ? HitTestMode.None : HitTestMode.Default)
                .accessibilityLevel(this.showCode ? 'no-hide-descendants' : 'auto')
                .onAreaChange((_old: Area, next: Area) => {
                  if (!this.fullscreen && !this.fullscreenClosing && !this.showCode && Number(next.height) > 0) {
                    this.inlineHeight = Number(next.height);
                  }
                })
              if (this.showCode) { this.codeView() }
            }.width('100%')
          }.id('preview-card-' + this.preview.id).width('100%').borderRadius(Radius.lg).clip(true)
        }.width('100%').padding({ left: Space.md, right: Space.md })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .bindContentCover($$this.fullscreen, this.fullscreenView(), { modalTransition: ModalTransition.NONE,
        backgroundColor: Color.Transparent, onWillDismiss: () => this.closeFullscreen(),
        onDisappear: () => this.fullscreenDidClose() })
  }
}
