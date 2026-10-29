import { Diagnostics } from '../model/Diagnostics';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { PublishedPreview } from '../model/PublishedPreview';
import { UiSavedState, UiValues } from '../model/InteractiveUi';
import { Attachments } from '../services/Attachments';
import { Btn, Radius, Space } from '../common/Theme';
import { UiPresentation } from '../model/UiPresentation';
import { IconButton } from '../common/Widgets';
import { PreviewFullscreen } from './PreviewFullscreen';
import { PreviewSurface, PreviewSurfaceOptions } from './PreviewSurface';

@Component
export struct PublishedPreviewCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
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
  @State private inlineHeight: number = 0;
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
    if (this.fullscreenClosing) { return; }
    this.surface.enterFullscreen(); this.fullscreen = true;
  }
  private closeFullscreen(): void {
    this.surface.exitFullscreen();
    if (this.fullscreen) { this.fullscreenClosing = true; }
    this.fullscreen = false;
  }
  private revisionChanged(): void {
    if (this.preview.superseded && !this.superseded) { this.expanded = false; }
    this.superseded = this.preview.superseded;
    this.surfaceChanged();
  }
  private thumbnailSize(): ImageSourceSize {
    const screenshot = this.preview.screenshot;
    if (!screenshot) { throw new Error('Preview thumbnail requires a screenshot'); }
    const scale = Math.min(264 / screenshot.width, 192 / screenshot.height);
    return { width: Math.max(1, Math.round(screenshot.width * scale)), height: Math.max(1, Math.round(screenshot.height * scale)) };
  }
  @Builder
  fullscreenView() {
    PreviewFullscreen({ title: this.preview.title, surface: this.surface, onClose: () => this.closeFullscreen() })
  }
  build() {
    Column({ space: Space.sm }) {
      if (this.inspectable || this.inspected) {
        Button(this.inspected ? t('在侧区查看') : t('在侧区打开')).attributeModifier(Btn.textSmall)
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
        Stack({ alignContent: Alignment.TopEnd }) {
        NodeContainer(this.surface.inlineMount).width('100%').height(this.fullscreen ? this.inlineHeight : undefined)
        IconButton({ icon: $r('sys.symbol.arrow_up_left_and_arrow_down_right'), label: t('全屏预览'),
          fill: $r('app.color.surface'), tint: $r('app.color.text_primary'),
          disabled: this.fullscreenClosing,
          compId: 'fullscreen-preview-' + this.preview.id, onTap: () => this.openFullscreen() })
          .margin({ top: 6, right: 6 })
        }.width('100%').onAreaChange((_old: Area, next: Area) => {
          if (!this.fullscreen) { this.inlineHeight = Number(next.height); }
        })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .bindContentCover($$this.fullscreen, this.fullscreenView(), { modalTransition: ModalTransition.ALPHA,
        backgroundColor: $r('app.color.surface'), onWillDismiss: () => this.closeFullscreen(),
        onDisappear: () => { this.fullscreenClosing = false; } })
  }
}
