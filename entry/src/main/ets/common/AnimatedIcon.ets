import { AnimatorResult } from '@kit.ArkUI';
import { AppearanceStyle } from './AppearanceStyle';
import { AnimatedIconName, iconPath, tinybotSpark } from './IconArtwork';

@Component
export struct AnimatedIcon {
  @StorageProp('tinybot.appearance.style') @Watch('availabilityChanged') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('availabilityChanged') private foreground: boolean = false;
  @Prop @Watch('selectionChanged') selected: boolean = false;
  @Prop @Watch('interactionChanged') interacting: boolean = false;
  @Prop tint: ResourceColor = $r('app.color.text_secondary');
  iconName: AnimatedIconName = 'mountain';
  iconSize: number = 18;
  playOnAppear: boolean = false;
  @State private progress: number = 1;
  private mounted: boolean = false;
  private animator?: AnimatorResult;

  aboutToAppear(): void { this.mounted = true; }
  aboutToDisappear(): void { this.mounted = false; this.stop(); }

  private selectionChanged(): void { if (this.selected) { this.play(); } }
  private interactionChanged(): void { if (this.interacting) { this.play(); } }
  private availabilityChanged(): void {
    if (!this.foreground || this.appearance.effectStrength === 0) { this.stop(); }
  }

  private play(): void {
    if (!this.mounted || !this.foreground || this.appearance.effectStrength === 0 || this.animator) { return; }
    const animator = this.getUIContext().createAnimator({
      duration: 300, easing: 'linear', delay: 0, fill: 'forwards',
      direction: 'normal', iterations: 1, begin: 0, end: 1
    });
    animator.onFrame = (progress: number): void => {
      if (this.animator === animator) { this.progress = progress; }
    };
    animator.onFinish = (): void => {
      if (this.animator === animator) { this.animator = undefined; this.progress = 1; }
    };
    this.animator = animator;
    animator.play();
  }

  private stop(): void {
    const animator = this.animator;
    this.animator = undefined;
    animator?.cancel();
    this.progress = 1;
  }

  build() {
    Shape() {
      if (this.iconName === 'tinybot') {
        Path().commands('M2.7 12.75 a8.7 8.7 0 1 0 17.4 0 a8.7 8.7 0 1 0 -17.4 0 Z').fill('#FAF9F5')
        Path().commands('M3.65 12.75 a7.75 7.75 0 1 0 15.5 0 a7.75 7.75 0 1 0 -15.5 0 Z').fill('#141413')
        Path().commands(iconPath('tinybot', this.progress, this.appearance.effectStrength)).fill('#FAF9F5')
        Path().commands(tinybotSpark(this.progress, this.appearance.effectStrength)).fill('#CC785C')
      } else {
        Path().commands(iconPath(this.iconName, this.progress, this.appearance.effectStrength))
          .fill(Color.Transparent).stroke(this.tint).strokeWidth('1.65px')
          .strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
      }
    }.viewPort({ x: 0, y: 0, width: '24px', height: '24px' })
      .width(this.iconSize).height(this.iconSize).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .onAppear(() => { if (this.playOnAppear) { this.play(); } })
  }
}
