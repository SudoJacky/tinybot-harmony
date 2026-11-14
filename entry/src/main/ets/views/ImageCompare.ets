import { image } from '@kit.ImageKit';
import { KeyCode } from '@kit.InputKit';
import { PathShape } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion } from '../common/Theme';
import { t } from '../model/I18n';

@Component
export struct ImageCompare {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  before?: image.PixelMap;
  @Prop cardId: string = '';
  @State private frameWidth: number = 0;
  @State private frameHeight: number = 0;
  @State private split: number = 0.5;
  @State private bend: number = 0;
  @State private dragging: boolean = false;
  @State private focused: boolean = false;
  private dragStart: number = 0;

  private move(value: number): void {
    const next = Math.max(0, Math.min(1, value));
    const delta = (next - this.split) * this.frameWidth;
    this.bend = this.appearance.effectStrength > 0 && this.dragging ? Math.max(-9, Math.min(9, delta * 0.6)) : 0;
    this.split = next;
  }

  private finish(): void {
    this.dragging = false;
    this.getUIContext().animateTo({ duration: Motion.fast, curve: Motion.standard }, () => { this.bend = 0; });
  }

  private seam(): string {
    // Path commands use physical pixels; layout and gesture offsets use vp.
    const ui = this.getUIContext();
    const width = ui.vp2px(this.frameWidth);
    const height = ui.vp2px(this.frameHeight);
    const x = this.split * width;
    const end = Math.max(0, Math.min(width, x - ui.vp2px(this.bend)));
    // The cubic passes through the grip at half height, with the ends slightly behind it.
    const control = end + (x - end) * 4 / 3;
    return 'M ' + end + ' 0 C ' + control + ' ' + height / 3 + ' ' +
      control + ' ' + (height * 2 / 3) + ' ' + end + ' ' + height;
  }

  private referenceClip(): PathShape {
    return new PathShape({ commands: this.seam() + ' L 0 ' + this.getUIContext().vp2px(this.frameHeight) + ' L 0 0 Z' });
  }

  @Builder
  tag(label: string) {
    Text(label).fontSize(11).fontWeight(FontWeight.Medium).fontFamily(this.appearance.fontFamily).fontColor(Color.White)
      .padding({ left: 9, right: 9, top: 3, bottom: 3 }).borderRadius(12).backgroundColor('#99000000')
      .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.frameWidth > 0 && this.frameHeight > 0) {
        Stack() {
          Image(this.before).width('100%').height('100%').objectFit(ImageFit.Contain)
        }.width('100%').height('100%').backgroundColor($r('app.color.surface_variant')).clipShape(this.referenceClip())
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
        Path().width(this.frameWidth).height(this.frameHeight).commands(this.seam()).fill(Color.Transparent)
          .stroke('#66000000').strokeWidth(3.5).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        Path().width(this.frameWidth).height(this.frameHeight).commands(this.seam()).fill(Color.Transparent)
          .stroke(Color.White).strokeWidth(1.5).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        Row() {
          if (this.split > 0.19) { this.tag(t('参考图')) }
          Blank()
          if (this.split < 0.81) { this.tag(t('生成结果')) }
        }.width('100%').padding(9).hitTestBehavior(HitTestMode.None)
        Stack() {
          Row({ space: 2 }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(11).fontColor([$r('app.color.text_primary')])
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(11).fontColor([$r('app.color.text_primary')])
          }.width(35).height(35).justifyContent(FlexAlign.Center).borderRadius(18).backgroundColor($r('app.color.surface'))
            .border({ width: this.focused ? 2 : 0, color: this.appearance.accent })
            .shadow({ radius: 8, color: '#44000000', offsetY: 2 })
            .scale({ x: this.dragging ? 0.94 : 1, y: this.dragging ? 0.94 : 1 })
            .animation({ duration: this.appearance.effectStrength > 0 ? Motion.fast : 0, curve: Motion.standard })
            .accessibilityLevel('no-hide-descendants')
        }.id(this.cardId + '-compare-slider').width(48).height(48)
          .position({ x: Math.max(0, Math.min(this.frameWidth - 48, this.split * this.frameWidth - 24)), y: (this.frameHeight - 48) / 2 })
          .focusable(true).focusOnTouch(false).onFocus(() => { this.focused = true; }).onBlur(() => { this.focused = false; })
          .accessibilityRole(AccessibilityRoleType.SLIDER)
          .accessibilityText(t('对比参考图与生成结果'))
          .accessibilityDescription(t('参考图 {0}%', [Math.round(this.split * 100)]))
          .onKeyEvent((event: KeyEvent) => {
            if (event.type !== KeyType.Down) { return; }
            if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT || event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
              this.move(this.split + (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT ? -0.1 : 0.1));
              event.stopPropagation();
            }
          })
          .gesture(PanGesture({ direction: PanDirection.Horizontal, fingers: 1, isFingerCountLimited: true, distance: 3 })
            .onActionStart(() => { this.dragStart = this.split; this.dragging = true; })
            .onActionUpdate((event: GestureEvent) => { this.move(this.dragStart + event.offsetX / this.frameWidth); })
            .onActionEnd(() => this.finish()).onActionCancel(() => this.finish()))
      }
    }.id(this.cardId + '-compare').width('100%').height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
      .onAreaChange((_previous: Area, area: Area) => { this.frameWidth = Number(area.width); this.frameHeight = Number(area.height); })
  }
}
