import { AnimatorResult } from '@kit.ArkUI';
import { t } from '../model/I18n';
import { Motion, Radius } from './Theme';
import { SwipeRowMotion as Swipe } from './SwipeRowMotion';

// Native implementation of a shared reveal drawer; no web component/runtime is used.
// A full swipe requests the same confirmation as the delete button, never deletes early.
@Component
export struct SwipeRow {
  @BuilderParam content: () => void;
  rowKey: string = '';
  label: string = '';
  radius: number = Radius.lg;
  @Prop @Watch('syncOpen') activeRow: string = '';
  @Prop @Watch('syncDisabled') disabled: boolean = false;
  onOpen: (key: string) => void = () => {};
  onDelete: () => void = () => {};
  onShare?: () => void;
  onExport?: () => void;
  @State private reveal: number = 0;
  @State private rowWidth: number = 0;
  @State private rowHeight: number = 1;
  private origin: number = 0;
  @State private dragging: boolean = false;
  private animator?: AnimatorResult;

  aboutToDisappear(): void { this.stop(); }
  private stop(): void {
    const animator = this.animator;
    // cancel() emits a final onFrame at the endpoint. Invalidate it first so
    // a new gesture continues from the displayed position, not that endpoint.
    this.animator = undefined;
    animator?.cancel();
  }
  private syncOpen(): void {
    if (this.activeRow !== this.rowKey) this.settle(false);
  }
  private syncDisabled(): void { if (this.disabled) { this.dragging = false; this.close(); } }
  private close(): void {
    this.settle(false);
    if (this.activeRow === this.rowKey) this.onOpen('');
  }
  private settle(open: boolean): void {
    this.stop();
    const from = this.reveal; const to = open ? Math.min(Swipe.drawer, this.rowWidth) : 0;
    if (Math.abs(from - to) < 0.1) { this.reveal = to; return; }
    // Physical springs cannot be sampled with ICurve.interpolate(). Let the
    // native animator resolve their timing and emit positions directly.
    const animator = this.getUIContext().createAnimator({ duration: 280,
      easing: 'interpolating-spring(0, 1, 230, 25)', delay: 0, fill: 'forwards',
      direction: 'normal', iterations: 1, begin: from, end: to });
    animator.onFrame = (position: number) => {
      if (this.animator !== animator) return;
      this.reveal = Math.max(0, Math.min(this.rowWidth, position));
    };
    animator.onFinish = () => {
      if (this.animator !== animator) return;
      this.reveal = to; this.animator = undefined;
    };
    this.animator = animator; animator.play();
  }
  private start(event: GestureEvent): void {
    if (this.disabled) return;
    this.stop(); this.origin = Swipe.dragOrigin(this.reveal); this.dragging = true;
    this.move(event);
  }
  private move(event: GestureEvent): void {
    if (this.disabled || !this.dragging) return;
    this.reveal = Swipe.reveal(this.origin - event.offsetX, this.rowWidth);
  }
  private end(event: GestureEvent): void {
    if (!this.dragging) return;
    this.move(event); this.dragging = false;
    if (this.disabled) { this.close(); return; }
    if (Swipe.armed(this.reveal, this.rowWidth) && event.velocityX <= 450) { this.requestDelete(); return; }
    const open = Swipe.staysOpen(this.reveal, event.velocityX);
    this.onOpen(open ? this.rowKey : ''); this.settle(open);
  }
  private requestDelete(): void {
    if (this.disabled || this.dragging) return;
    this.onOpen(''); this.close(); this.onDelete();
  }
  @Builder
  deleteIcon() {
    Stack() {
      Shape() {
        Path().commands('M6 9 L7 20 Q7 22 9 22 H15 Q17 22 17 20 L18 9 M10 11 V18 M14 11 V18')
      }.viewPort({ x: 0, y: 0, width: '24px', height: '24px' })
      .width(24).height(24).fill(Color.Transparent).stroke($r('app.color.on_danger'))
      .strokeWidth('1.7px').strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
      Shape() {
        Path().commands('M4 7 H20 M9 7 V4 Q9 3 10 3 H14 Q15 3 15 4 V7')
      }.viewPort({ x: 0, y: 0, width: '24px', height: '24px' })
      .width(24).height(24).fill(Color.Transparent).stroke($r('app.color.on_danger'))
      .strokeWidth('1.7px').strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
      .id('swipe-delete-lid-' + this.rowKey)
      .rotate({ angle: Swipe.armed(this.reveal, this.rowWidth) ? -28 : 0, centerX: 4, centerY: 7 })
      .translate({ y: Swipe.armed(this.reveal, this.rowWidth) ? -1 : 0 })
      .animation({ duration: Motion.fast, curve: Motion.standard })
    }.width(24).height(24).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
  @Builder
  actionsMenu() {
    Menu() {
      if (this.onShare) {
        MenuItem({ content: t('分享') }).enabled(!this.disabled).onClick(() => this.onShare?.())
      }
      if (this.onExport) {
        MenuItem({ content: t('导出到文件') }).enabled(!this.disabled).onClick(() => this.onExport?.())
      }
      MenuItem({ content: t('删除') }).contentFontColor($r('app.color.danger'))
        .enabled(!this.disabled).onClick(() => this.requestDelete())
    }
  }
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 4 }) {
          this.deleteIcon()
          Text(t('删除')).fontSize(12).fontColor($r('app.color.on_danger'))
        }.opacity(Math.min(1, this.reveal / 48)).width('100%')
      }.id('swipe-delete-' + this.rowKey).width(Math.max(1, this.reveal)).height(this.rowHeight)
      .position({ x: Math.max(0, this.rowWidth - this.reveal), y: 0 })
      .backgroundColor($r('app.color.danger')).borderRadius(this.radius)
      .enabled(!this.disabled && this.reveal >= 32).opacity(this.reveal > 0 ? 1 : 0)
      .accessibilityLevel(this.reveal >= 32 ? 'auto' : 'no-hide-descendants')
      .accessibilityText(t('删除') + ' ' + this.label).onClick(() => this.requestDelete())
      Column() { this.content() }
        .width('100%').translate({ x: -this.reveal })
        .onAreaChange((_old: Area, area: Area) => { this.rowHeight = Number(area.height); })
      // Add a tap-to-close cover only after release. Changing the content's hit test
      // during the pan would cancel the recognizer which owns that gesture.
      if (!this.dragging && this.reveal > 1) {
        Column().width(Math.max(0, this.rowWidth - this.reveal)).height(this.rowHeight)
          .position({ x: 0, y: 0 }).backgroundColor(Color.Transparent)
          .accessibilityLevel('no').onClick(() => this.close())
      }
    }.id('swipe-row-' + this.rowKey).width('100%').borderRadius(this.radius).clip(true)
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      if (this.rowWidth > 0 && Math.abs(width - this.rowWidth) > 1) this.close();
      this.rowWidth = width;
    })
    .onVisibleAreaChange([0], (visible: boolean) => { if (!visible) { this.stop(); this.reveal = 0; this.dragging = false; } })
    .bindContextMenu(this.actionsMenu, ResponseType.LongPress)
    .priorityGesture(PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Horizontal, distance: 12 })
      .onActionStart((event: GestureEvent) => this.start(event))
      .onActionUpdate((event: GestureEvent) => this.move(event))
      .onActionEnd((event: GestureEvent) => this.end(event))
      .onActionCancel(() => { this.dragging = false; this.close(); }))
  }
}
