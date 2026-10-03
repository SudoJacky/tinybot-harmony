import { AnimatorResult } from '@kit.ArkUI';
import { LiquidToggleMotion as Liquid } from './LiquidToggleMotion';
import { Motion } from './Theme';

// Bencho Liquid Toggle, adapted to ArkUI. See THIRD_PARTY_NOTICES.txt.
// Theme resources replace the web demo's CSS tokens; no web runtime is needed.
@Component
export struct LiquidToggle {
  @Prop @Watch('syncSelection') isOn: boolean = false;
  @Prop @Watch('syncDisabled') disabled: boolean = false;
  @Prop speed: number = 50;
  @Prop stretch: number = 36;
  @Prop label: string = '';
  compId: string = '';
  onChange: (value: boolean) => void = () => {};

  @State private thumbPosition: number = 0;
  @State private thumbScale: number = 1;
  @State private selected: boolean = false;
  @State private preview: boolean = false;
  private animator?: AnimatorResult;
  private generation: number = 0;
  private velocity: number = 0;
  private dragging: boolean = false;
  private dragOrigin: number = 0;
  private dragOffset: number = 0;

  aboutToAppear(): void {
    this.selected = this.isOn;
    this.preview = this.isOn;
    this.thumbPosition = Liquid.endpoint(this.isOn);
  }

  aboutToDisappear(): void {
    this.dragging = false;
    this.stopAnimation();
  }

  private stopAnimation(): void {
    this.generation++;
    this.animator?.cancel();
    this.animator = undefined;
  }

  private syncSelection(): void {
    // Parent updates (including failed-save rollback) always win over a gesture.
    this.dragging = false;
    this.selected = this.isOn;
    this.settle();
  }

  private syncDisabled(): void {
    if (this.disabled) {
      this.dragging = false;
      this.selected = this.isOn;
      this.settle();
    }
  }

  private settle(): void {
    this.stopAnimation();
    this.preview = this.selected;
    const from = this.thumbPosition;
    const target = Liquid.endpoint(this.selected);
    const velocity = this.velocity;
    if (Math.abs(from - target) < 0.01 && Math.abs(velocity) < 1) {
      this.thumbPosition = target;
      this.thumbScale = 1;
      this.velocity = 0;
      return;
    }
    const generation = this.generation;
    const animator = this.getUIContext().createAnimator({
      duration: Liquid.duration, easing: 'linear', delay: 0, fill: 'forwards',
      direction: 'normal', iterations: 1, begin: 0, end: 1
    });
    animator.onFrame = (progress: number): void => {
      if (generation !== this.generation) return;
      const frame = Liquid.sample(from, target, velocity, progress * Liquid.duration / 1000, this.speed);
      this.thumbPosition = Liquid.clamp(frame.position, 0, Liquid.travel);
      this.velocity = frame.velocity;
      this.thumbScale = Liquid.stretch(frame.velocity, this.stretch);
    };
    animator.onFinish = (): void => {
      if (generation !== this.generation) return;
      this.thumbPosition = target;
      this.velocity = 0;
      this.thumbScale = 1;
      this.animator = undefined;
    };
    this.animator = animator;
    animator.play();
  }

  private commit(value: boolean): void {
    const changed = value !== this.selected;
    this.selected = value;
    this.settle();
    // Preview is local. Persist once on release, never on every midpoint crossing.
    if (changed) this.onChange(value);
  }

  private startDrag(event: GestureEvent): void {
    if (this.disabled) return;
    this.stopAnimation();
    this.dragging = true;
    // Capture the offset at recognition, so grabbing the rail never teleports the thumb.
    this.dragOrigin = this.thumbPosition;
    this.dragOffset = event.offsetX;
    this.velocity = 0;
  }

  private moveDrag(event: GestureEvent): void {
    if (!this.dragging || this.disabled) return;
    this.thumbPosition = Liquid.clamp(this.dragOrigin + event.offsetX - this.dragOffset, 0, Liquid.travel);
    this.velocity = this.velocity * 0.6 + Liquid.clamp(event.velocityX, -1500, 1500) * 0.4;
    this.thumbScale = Liquid.stretch(this.velocity, this.stretch);
    this.preview = Liquid.selection(this.thumbPosition);
  }

  private endDrag(event: GestureEvent): void {
    if (!this.dragging || this.disabled) return;
    this.moveDrag(event);
    this.dragging = false;
    this.commit(Liquid.selection(this.thumbPosition));
  }

  private cancelDrag(): void {
    if (!this.dragging) return;
    this.dragging = false;
    this.velocity = 0;
    this.settle();
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Stack({ alignContent: Alignment.Start }) {
        // One solid body. Scale inside a translated wrapper so deformation does
        // not alter the endpoints or introduce a second coordinate system.
        Stack() {
          Circle().width(Liquid.thumbSize).height(Liquid.thumbSize)
            .fill(this.preview ? $r('app.color.on_accent') : $r('app.color.text_tertiary'))
            .scale({ x: this.thumbScale, y: 1 / this.thumbScale })
        }.width(Liquid.thumbSize).height(Liquid.thumbSize)
        .translate({ x: Liquid.pad + this.thumbPosition })
      }
      .width(Liquid.railWidth).height(Liquid.railHeight).borderRadius(Liquid.railHeight / 2)
      .backgroundColor(this.preview ? $r('app.color.accent') : $r('app.color.surface_variant'))
      .animation({ duration: Motion.fast, curve: Motion.standard })
      .accessibilityLevel('no-hide-descendants').hitTestBehavior(HitTestMode.None)
    }
    .id(this.compId).width(Liquid.railWidth).height(48).padding(0)
    .borderRadius(24).backgroundColor(Color.Transparent).enabled(!this.disabled)
    .accessibilityText(this.label).accessibilityRole(AccessibilityRoleType.SWITCH)
    .accessibilityChecked(this.selected)
    .onClick(() => { if (!this.disabled && !this.dragging) this.commit(!this.selected); })
    .gesture(PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Horizontal, distance: 4 })
      .onActionStart((event: GestureEvent) => this.startDrag(event))
      .onActionUpdate((event: GestureEvent) => this.moveDrag(event))
      .onActionEnd((event: GestureEvent) => this.endDrag(event))
      .onActionCancel(() => this.cancelDrag()))
  }
}
