import { image } from '@kit.ImageKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Space, systemInsets } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { BrowserAnnotation } from '../model/BrowserAnnotation';
import { renderBrowserAnnotation } from '../services/BrowserAnnotationImage';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';

@Component
export struct BrowserAnnotationBoard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink draft: BrowserAnnotation;
  // Keep this immutable native handle out of @Prop's object copying/proxying.
  pixel?: image.PixelMap;
  @Prop pageTitle: string = '';
  @Prop captureWidth: number = 0;
  @Prop captureHeight: number = 0;
  onClose: () => void = () => {};
  onAdd: (pixel: image.PixelMap, note: string) => Promise<void> = async () => {};
  @State private error: string = '';
  @State private frameWidth: number = 0;
  @State private frameHeight: number = 0;
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;
  private pointer: number = -1;
  aboutToAppear(): void {
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetTop = insets[0]; this.insetBottom = insets[1]; });
  }
  aboutToDisappear(): void {
    this.pixel?.release().catch((error: Error) => Diagnostics.log('error', 'browser', 'annotation_failed', undefined, error));
  }
  private draw(): void {
    if (!this.ready) { return; }
    const ctx = this.canvas;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight); ctx.strokeStyle = '#e53935'; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    for (const stroke of this.draft.strokes) {
      const first = stroke.points[0]; if (!first) { continue; }
      ctx.lineWidth = stroke.width * this.canvasWidth; ctx.beginPath();
      ctx.moveTo(first.x * this.canvasWidth, first.y * this.canvasHeight); ctx.lineTo(first.x * this.canvasWidth + 0.01, first.y * this.canvasHeight);
      for (const point of stroke.points.slice(1)) { ctx.lineTo(point.x * this.canvasWidth, point.y * this.canvasHeight); }
      ctx.stroke();
    }
  }
  private touch(event: TouchEvent): void {
    event.stopPropagation();
    if (this.draft.saving || this.canvasWidth <= 0 || this.canvasHeight <= 0) { return; }
    if (event.type === TouchType.Cancel || event.touches.length > 1) { this.pointer = -1; this.draft.end(); return; }
    const point = event.changedTouches.find((item: TouchObject) => this.pointer < 0 || item.id === this.pointer);
    if (!point) { return; }
    const x = Math.max(0, Math.min(1, point.x / this.canvasWidth));
    const y = Math.max(0, Math.min(1, point.y / this.canvasHeight));
    if (event.type === TouchType.Down && this.pointer < 0) {
      this.getUIContext().getFocusController().clearFocus();
      this.pointer = point.id; this.draft.begin(x, y, 3 / this.canvasWidth);
    } else if (this.pointer === point.id) { this.draft.move(x, y); }
    if (event.type === TouchType.Up) { this.pointer = -1; this.draft.end(); }
    this.draw();
  }
  private async add(): Promise<void> {
    if (this.draft.saving) { return; }
    this.draft.end(); this.pointer = -1; this.draft.saving = true; this.error = '';
    let pixel: image.PixelMap | undefined;
    try {
      if (!this.pixel) { throw new Error(t('批注截图已失效，请重新截取。')); }
      pixel = await renderBrowserAnnotation(this.pixel, this.draft.strokes); await this.onAdd(pixel, this.draft.note);
    }
    catch (error) { this.error = (error as Error).message; Diagnostics.log('error', 'browser', 'annotation_failed', undefined, error as Error); }
    finally { try { await pixel?.release(); } finally { this.draft.saving = false; } }
  }
  @Builder
  private header() {
    Row({ space: Space.sm }) {
      IconButton({ icon: $r('sys.symbol.xmark'), label: t('取消'), compId: 'annotation-cancel', disabled: this.draft.saving, onTap: this.onClose })
      Text(t('批注当前页面')).fontFamily(this.appearance.fontFamily).fontSize(Font.title).fontWeight(FontWeight.Medium).layoutWeight(1)
      Button(this.draft.saving ? t('添加中…') : t('添加到消息')).fontFamily(this.appearance.fontFamily).id('annotation-add')
        .attributeModifier(Btn.primarySmall).enabled(!this.draft.saving).onClick(() => this.add())
    }.width('100%').height(52)
  }
  build() {
    Navigation() {
      Column({ space: Space.sm }) {
        Text(this.pageTitle).fontFamily(this.appearance.fontFamily).fontSize(12).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary')).width('100%')
        Stack() {
          Stack() {
            Image(this.pixel).width('100%').height('100%').objectFit(ImageFit.Fill)
            Canvas(this.canvas).width('100%').height('100%').id('annotation-canvas')
              .accessibilityText(t('在截图上圈画批注'))
              .onReady(() => { this.ready = true; this.draw(); })
              .onAreaChange((_old, area) => { this.canvasWidth = Number(area.width); this.canvasHeight = Number(area.height); this.draw(); })
              .onTouch((event: TouchEvent) => this.touch(event))
          }.width(this.frameWidth).height(this.frameHeight).clip(true).enabled(!this.draft.saving)
        }.width('100%').layoutWeight(1).backgroundColor($r('app.color.surface_variant'))
          .onAreaChange((_old, area) => {
            const scale = Math.min(Number(area.width) / this.captureWidth, Number(area.height) / this.captureHeight);
            this.frameWidth = this.captureWidth * scale; this.frameHeight = this.captureHeight * scale;
          })
        Row({ space: Space.sm }) {
          Text(t('用手指圈画，或在下方填写说明。')).fontFamily(this.appearance.fontFamily).fontSize(12).layoutWeight(1).fontColor($r('app.color.text_secondary'))
          Button(t('撤销')).fontFamily(this.appearance.fontFamily).id('annotation-undo').attributeModifier(Btn.textSmall)
            .enabled(!this.draft.saving && this.draft.strokes.length > 0).onClick(() => { this.draft.undo(); this.draw(); })
          Button(t('清空')).fontFamily(this.appearance.fontFamily).id('annotation-clear').attributeModifier(Btn.textSmall)
            .enabled(!this.draft.saving && this.draft.strokes.length > 0).onClick(() => { this.draft.clear(); this.draw(); })
        }.width('100%')
        TextArea({ text: this.draft.note, placeholder: t('告诉 Tinybot 需要关注或修改什么…') }).fontFamily(this.appearance.fontFamily)
          .id('annotation-note').height(88).maxLength(4000).enabled(!this.draft.saving).onChange((value: string) => { this.draft.note = value; })
        if (this.error) { Text(this.error).id('annotation-error').fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.danger')).width('100%') }
      }.width('100%').height('100%')
    }.title({ builder: this.header, height: 52 }, { barStyle: BarStyle.STANDARD,
      backgroundColor: Color.Transparent, backgroundEffect: { radius: 0, color: Color.Transparent } })
      .hideBackButton(true).titleMode(NavigationTitleMode.Mini).hideToolBar(true).mode(NavigationMode.Stack)
      .width('100%').height('100%').padding({ left: Space.md, right: Space.md, top: this.insetTop + 4, bottom: this.insetBottom + Space.sm })
      .backgroundColor($r('app.color.page_background')).expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
