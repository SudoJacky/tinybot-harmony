import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { systemInsets } from '../common/Theme';

// Full-screen image viewer: pinch or double-tap to zoom, drag when zoomed, tap or back to close.
// The source is a complete image source, so attachments pass file:// paths and replies pass URLs.
@Component
export struct ImageViewer {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  source: string = '';
  onClose: () => void = () => {};
  @State private zoom: number = 1;
  @State private insetTop: number = 0;
  @State private offsetX: number = 0;
  @State private offsetY: number = 0;
  private pinchBase: number = 1;
  private panBaseX: number = 0;
  private panBaseY: number = 0;

  aboutToAppear(): void {
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetTop = insets[0]; });
  }

  private reset(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
      this.zoom = 1; this.offsetX = 0; this.offsetY = 0;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image(this.source).width('100%').height('100%').objectFit(ImageFit.Contain)
        .scale({ x: this.zoom, y: this.zoom }).translate({ x: this.offsetX, y: this.offsetY })
        .gesture(GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => {
            if (this.zoom > 1) { this.reset(); return; }
            this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => { this.zoom = 2.5; });
          }),
          TapGesture({ count: 1 }).onAction(() => this.onClose()),
          PinchGesture()
            .onActionStart(() => { this.pinchBase = this.zoom; })
            .onActionUpdate((event: GestureEvent) => { this.zoom = Math.min(5, Math.max(1, this.pinchBase * event.scale)); })
            .onActionEnd(() => { if (this.zoom <= 1.05) { this.reset(); } }),
          PanGesture()
            .onActionStart(() => { this.panBaseX = this.offsetX; this.panBaseY = this.offsetY; })
            .onActionUpdate((event: GestureEvent) => {
              if (this.zoom > 1) { this.offsetX = this.panBaseX + event.offsetX; this.offsetY = this.panBaseY + event.offsetY; }
            })))
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([Color.White])
      }.fontFamily(this.appearance.fontFamily).width(44).height(44).backgroundColor('#4D000000').margin({ top: this.insetTop + 8, right: 12 })
      .accessibilityText(t("关闭")).onClick(() => this.onClose())
    }.width('100%').height('100%').backgroundColor(Color.Black)
  }
}
