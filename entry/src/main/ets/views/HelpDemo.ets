import { AppearanceStyle } from '../common/AppearanceStyle';
import { AnimatorResult } from '@kit.ArkUI';
import { Radius } from '../common/Theme';
import { HelpDemoKind, TutorialStep, TutorialRect, TUTORIAL_STEP_MS, tutorialSteps, tutorialRect,
  tutorialResultRect, tutorialEase, tutorialPage } from '../model/HelpTutorial';
import { HelpTutorialScreen, tutorialText } from './HelpTutorialScreen';

@Component
export struct HelpDemo {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  kind: HelpDemoKind = 'chat';
  @StorageProp('tinybot.foreground') @Watch('syncPlayback') private foreground: boolean = false;
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @State private steps: TutorialStep[] = tutorialSteps('chat');
  @State private index: number = 0;
  @State private phase: number = 0;
  @State private stageWidth: number = 300;
  private mounted: boolean = false;
  private visible: boolean = false;
  private playing: boolean = false;
  private animator?: AnimatorResult;

  aboutToAppear(): void { this.steps = tutorialSteps(this.kind); this.mounted = true; }

  aboutToDisappear(): void {
    this.mounted = false; this.visible = false; this.playing = false;
    const animator = this.animator; this.animator = undefined; animator?.cancel();
  }

  private syncPlayback(): void {
    const active = this.mounted && this.visible && this.foreground;
    if (active === this.playing) { return; }
    this.playing = active;
    if (!active) { this.animator?.pause(); return; }
    if (!this.animator) {
      const animator = this.getUIContext().createAnimator({ duration: this.steps.length * TUTORIAL_STEP_MS,
        easing: 'linear', delay: 0, fill: 'forwards', direction: 'normal', iterations: -1, begin: 0, end: this.steps.length });
      this.animator = animator;
      animator.onFrame = (value: number): void => {
        if (!this.mounted || !this.playing || this.animator !== animator) { return; }
        this.index = Math.min(this.steps.length - 1, Math.floor(value)); this.phase = value - this.index;
      };
    }
    this.animator.play();
  }

  private navigation(): number { return tutorialEase((this.phase - 0.48) / 0.18); }
  private focus(): number {
    // Establish the page once, retain close-ups between actions, then reset only at the loop boundary.
    const enter = this.index === 0 ? tutorialEase((this.phase - 0.08) / 0.24) : 1;
    const exit = this.index === this.steps.length - 1 ? 1 - tutorialEase((this.phase - 0.84) / 0.16) : 1;
    return enter * exit;
  }
  private zoom(): number {
    const rect = this.cameraRect();
    const base = Math.min((this.stageWidth - 24) / 360, 296 / 720);
    const focused = Math.min(1.2, (this.stageWidth - 24) / Math.min(360, rect.width + 80), 296 / Math.max(180, rect.height + 100));
    return base + (focused - base) * this.focus();
  }
  private cameraRect(): TutorialRect {
    let from = tutorialRect(this.steps[this.index].control);
    let to = tutorialResultRect(this.steps[this.index]);
    let travel = tutorialEase((this.phase - 0.5) / 0.18);
    if (this.phase < 0.5) {
      to = from;
      if (this.index > 0 && this.steps[this.index - 1].after === this.steps[this.index].screen) {
        from = tutorialResultRect(this.steps[this.index - 1]);
      }
      travel = tutorialEase(this.phase / 0.32);
    }
    return { x: from.x + (to.x - from.x) * travel, y: from.y + (to.y - from.y) * travel,
      width: from.width + (to.width - from.width) * travel, height: from.height + (to.height - from.height) * travel };
  }
  private cameraOffset(viewport: number, content: number, anchor: number): number {
    const scaled = content * this.zoom();
    if (scaled <= viewport - 24) { return (viewport - scaled) / 2; }
    return Math.max(viewport - scaled - 12, Math.min(12, viewport / 2 - anchor * this.zoom()));
  }
  private cameraX(): number {
    const rect = this.cameraRect();
    return this.cameraOffset(this.stageWidth, 360, 180 + (rect.x + rect.width / 2 - 180) * this.focus());
  }
  private cameraY(): number {
    const rect = this.cameraRect();
    return this.cameraOffset(320, 720, 360 + (rect.y + rect.height / 2 - 360) * this.focus());
  }
  private pointerX(): number {
    const rect = tutorialRect(this.steps[this.index].control);
    const travel = tutorialEase((this.phase - 0.12) / 0.25);
    return rect.x + rect.width / 2 - 52 * (1 - travel) + Math.sin(travel * Math.PI) * 14;
  }
  private pointerY(): number {
    const rect = tutorialRect(this.steps[this.index].control);
    return rect.y + rect.height / 2 + 64 * (1 - tutorialEase((this.phase - 0.12) / 0.25));
  }
  private pointerAlpha(): number {
    return Math.min(tutorialEase((this.phase - 0.12) / 0.08), 1 - tutorialEase((this.phase - 0.48) / 0.1));
  }
  private tap(): number { return Math.max(0, 1 - Math.abs(this.phase - 0.43) / 0.06); }
  private ripple(): number { return Math.max(0, Math.min(1, (this.phase - 0.43) / 0.2)); }
  private stageAlpha(): number {
    const incomingCut = this.index === 0 || this.steps[this.index - 1].after !== this.steps[this.index].screen;
    const outgoingCut = this.index === this.steps.length - 1 || this.steps[this.index].after !== this.steps[this.index + 1].screen;
    return Math.min(incomingCut ? tutorialEase(this.phase / 0.08) : 1,
      outgoingCut ? 1 - tutorialEase((this.phase - 0.9) / 0.1) : 1);
  }
  private isOverlay(): boolean {
    const after = this.steps[this.index].after;
    return after === 'menu' || after === 'plus' || after === 'presets';
  }
  private pageChange(): boolean {
    return tutorialPage(this.steps[this.index].screen) !== tutorialPage(this.steps[this.index].after);
  }

  @Builder
  touch() {
    Rect().width(tutorialRect(this.steps[this.index].control).width + 8)
      .height(tutorialRect(this.steps[this.index].control).height + 8).radius(14)
      .fill(Color.Transparent).stroke(this.appearance.accent).strokeWidth(2)
      .position({ x: tutorialRect(this.steps[this.index].control).x - 4, y: tutorialRect(this.steps[this.index].control).y - 4 })
      .opacity(this.focus() * (1 - this.navigation()) * 0.8)
    Circle().width(32).height(32).fill(Color.Transparent).stroke(this.appearance.accent).strokeWidth(2)
      .position({ x: this.pointerX() - 16, y: this.pointerY() - 16 })
      .scale({ x: 1 + this.ripple() * 1.8, y: 1 + this.ripple() * 1.8 })
      .opacity(this.phase >= 0.43 ? (1 - this.ripple()) * 0.8 : 0)
    Circle().width(20).height(20).fill($r('app.color.surface')).stroke(this.appearance.accent).strokeWidth(3)
      .position({ x: this.pointerX() - 10, y: this.pointerY() - 10 })
      .scale({ x: 1 - this.tap() * 0.2, y: 1 - this.tap() * 0.2 }).opacity(this.pointerAlpha())
  }

  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Stack({ alignContent: Alignment.TopStart }) {
          HelpTutorialScreen({ screen: this.steps[this.index].screen, locale: this.locale, motion: this.phase })
            .translate({ x: this.pageChange() && !this.isOverlay() ? -48 * this.navigation() : 0 })
          if (this.steps[this.index].after !== this.steps[this.index].screen) {
            HelpTutorialScreen({ screen: this.steps[this.index].after, locale: this.locale,
              typing: tutorialEase((this.phase - 0.55) / 0.25), overlayOnly: this.isOverlay(), motion: this.phase })
              .opacity(this.navigation())
              .translate({ x: this.pageChange() && !this.isOverlay() ? 360 * (1 - this.navigation()) : 0,
                y: this.steps[this.index].after === 'plus' || this.steps[this.index].after === 'presets' ? 200 * (1 - this.navigation()) : 0 })
          }
          this.touch()
        }.width(360).height(720).borderRadius(18).clip(true)
          .border({ width: 0.5, color: $r('app.color.divider') })
          .scale({ x: this.zoom(), y: this.zoom(), centerX: 0, centerY: 0 })
          .translate({ x: this.cameraX(), y: this.cameraY() }).opacity(this.stageAlpha())
          .position({ x: 0, y: 0 })
      }.width('100%').height(320).borderRadius(Radius.md).clip(true)
        .backgroundColor($r('app.color.surface_variant')).hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no-hide-descendants')
        .onAreaChange((oldArea: Area, area: Area) => { this.stageWidth = Number(area.width); })
      Text(tutorialText(this.steps[this.index].caption, this.locale)).fontFamily(this.appearance.fontFamily).fontSize(12).maxLines(2)
        .fontColor($r('app.color.text_secondary')).width('100%').constraintSize({ minHeight: 32 })
      Progress({ value: this.index + this.phase, total: this.steps.length, type: ProgressType.Linear })
        .width('100%').height(2).color(this.appearance.accent).backgroundColor($r('app.color.divider'))
        .accessibilityLevel('no')
    }.width('100%').id('help-demo-' + this.kind)
      .onVisibleAreaChange([0], (visible: boolean) => {
        this.visible = visible; this.syncPlayback();
      })
  }
}
