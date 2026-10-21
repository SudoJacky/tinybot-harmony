import { AnimatorResult, curves } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';

// The same single eye and brand-orange satellite as the app mark, drawn natively.
// Every child is sized from diameter, so the component never overflows its layout box.
@Component
export struct OnboardingMascot {
  @StorageProp('tinybot.appearance.style') @Watch('syncPlayback') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncPlayback') private foreground: boolean = false;
  @StorageProp('tinybot.appearance.dark') private dark: boolean = false;
  @Prop scene: number = 0;
  @Prop greeted: boolean = false;
  @Prop diameter: number = 220;
  @Prop @Watch('wakeChanged') sleepy: boolean = false;
  @Prop @Watch('wakeChanged') waking: boolean = false;
  @Prop energized: boolean = false;
  @Prop allowDrag: boolean = false;
  @Prop connected: boolean = false;
  @Prop @Watch('attentionChanged') lookX: number = 0;
  @Prop @Watch('attentionChanged') lookY: number = 0;
  @Prop @Watch('coverChanged') coverEyes: boolean = false;
  @Prop @Watch('syncPlayback') active: boolean = true;
  // sleepy, surprised, happy, curious, focused or proud; unknown values stay neutral.
  @Prop @Watch('moodChanged') mood: string = 'neutral';
  onHello: () => void = () => {};
  @State private phase: number = 0;
  @State private wakeProgress: number = 0;
  @State private moodVisual: string = 'neutral';
  @State private gazeX: number = 0;
  @State private gazeY: number = 0;
  @State private dragX: number = 0;
  @State private dragY: number = 0;
  @State private reaction: number = 0;
  @State private attentionX: number = 0;
  @State private attentionY: number = 0;
  @State private coverProgress: number = 0;
  @State private peekProgress: number = 0;
  private feedback: number = 0;
  private tapCount: number = 0;
  private mounted: boolean = false;
  private visible: boolean = false;
  private playing: boolean = false;
  private dragging: boolean = false;
  private settling: boolean = false;
  private dragged: boolean = false;
  private reacting: boolean = false;
  private feedbackRevision: number = 0;
  private peekTimer: number = -1;
  private peekRevision: number = 0;
  private animator?: AnimatorResult;

  aboutToAppear(): void {
    this.mounted = true;
    this.moodVisual = this.mood;
    this.wakeProgress = this.waking ? 1 : 0;
    this.attentionX = this.lookX;
    this.attentionY = this.lookY;
    this.coverProgress = this.coverEyes ? 1 : 0;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.cancelPeek();
    this.playing = false;
    this.visible = false;
    this.dragging = false;
    this.settling = false;
    this.reacting = false;
    this.feedbackRevision++;
    const animator = this.animator;
    this.animator = undefined;
    animator?.cancel();
  }

  private visibilityChanged(ratio: number): void {
    // The callback's boolean means expanding/shrinking, not visible/hidden.
    this.visible = ratio > 0;
    this.syncPlayback();
  }

  // Expressions travel on the same spring as the rest of the character. Hidden,
  // covered, backgrounded or motion-off actors change pose without an animation.
  private moodChanged(): void {
    const next = this.mood;
    if (!this.mounted || !this.playing || this.appearance.effectStrength === 0) {
      this.moodVisual = next;
      return;
    }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.78) }, () => {
      this.moodVisual = next;
    });
  }

  private syncPlayback(): void {
    const unavailable = this.active === false || !this.foreground || !this.visible;
    if (unavailable || this.appearance.effectStrength === 0) {
      this.cancelPeek();
      this.coverProgress = this.coverEyes ? 1 : 0;
      this.peekProgress = 0;
      this.feedbackRevision++;
      this.settling = false;
      this.reacting = false;
      this.reaction = 0;
      if (unavailable) {
        this.dragging = false;
        this.dragX = 0;
        this.dragY = 0;
      }
    }
    const active = this.mounted && this.active !== false && this.visible && this.foreground &&
      this.appearance.effectStrength > 0;
    if (active === this.playing) { return; }
    this.playing = active;
    if (!active) {
      this.animator?.pause();
      return;
    }
    if (!this.animator) {
      const animator = this.getUIContext().createAnimator({ duration: 4800, easing: 'linear', delay: 0,
        fill: 'forwards', direction: 'normal', iterations: -1, begin: 0, end: 1 });
      this.animator = animator;
      animator.onFrame = (value: number): void => {
        if (this.mounted && this.playing && this.animator === animator) { this.phase = value; }
      };
    }
    this.animator.play();
    if (this.coverEyes) { this.coverChanged(); }
  }

  private attentionChanged(): void {
    const change = (): void => { this.attentionX = this.lookX; this.attentionY = this.lookY; };
    if (!this.mounted || !this.playing || this.appearance.effectStrength === 0) { change(); return; }
    this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, change);
  }

  private cancelPeek(): void {
    this.peekRevision++;
    if (this.peekTimer >= 0) { clearTimeout(this.peekTimer); this.peekTimer = -1; }
  }

  private coverChanged(): void {
    this.cancelPeek();
    const change = (): void => {
      this.coverProgress = this.coverEyes ? 1 : 0;
      this.peekProgress = 0;
    };
    if (!this.mounted || !this.playing || this.appearance.effectStrength === 0) { change(); return; }
    this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseOut }, change);
    if (!this.coverEyes) { return; }
    const revision = this.peekRevision;
    this.peekTimer = setTimeout(() => {
      if (!this.mounted || !this.playing || !this.coverEyes || revision !== this.peekRevision) { return; }
      this.peekTimer = -1;
      this.getUIContext().animateTo({ duration: 440, curve: Curve.EaseInOut }, () => { this.peekProgress = 1; });
    }, 850);
  }

  private unit(value: number): number { return value * this.diameter / 220; }

  private wakeChanged(): void {
    const change = (): void => { this.wakeProgress = this.waking ? 1 : 0; };
    if (!this.mounted || !this.playing || !this.waking || this.appearance.effectStrength === 0) {
      change();
      return;
    }
    this.getUIContext().animateTo({ duration: 1200, curve: Curve.EaseInOut }, change);
  }

  private sleepAmount(): number {
    return this.sleepy === true ? 1 - this.wakeProgress : 0;
  }

  private sleepBreath(): number {
    return Math.sin(this.phase * Math.PI * 2) * 0.025 * this.sleepAmount() * this.appearance.effectStrength;
  }

  private sleepDrift(index: number): number {
    return this.appearance.effectStrength > 0 ? (this.phase + index / 3) % 1 : (index + 1) / 4;
  }

  private lift(): number {
    if (this.dragging === true || this.settling === true) { return 0; }
    if (this.active === false || this.appearance.effectStrength === 0) { return 0; }
    return Math.sin(this.phase * Math.PI * 2) * 5 * (1 - this.sleepAmount() * 0.45) * this.appearance.effectStrength;
  }

  private eyeHeight(): number {
    if (this.sleepy === true) { return 0.12 + this.wakeProgress * 0.88; }
    if (this.moodVisual === 'sleepy') { return 0.3; }
    if (this.appearance.effectStrength === 0) { return 1; }
    if (this.feedback === 1) { return 1 - this.reaction * 0.92; }
    const blink = Math.max(0, 1 - Math.abs(this.phase - 0.58) / 0.018);
    return 1 - blink * 0.9;
  }

  private isSleepy(): boolean {
    return this.sleepy === true || this.moodVisual === 'sleepy';
  }

  // The eye keeps its base diameter and node; mood only changes its transform.
  private eyeScaleX(): number {
    if (this.moodVisual === 'surprised') { return 1.18; }
    if (this.moodVisual === 'focused') { return 1.03; }
    if (this.moodVisual === 'happy') { return 1.06; }
    if (this.moodVisual === 'proud') { return 1.02; }
    if (this.moodVisual === 'curious') { return 1.04; }
    if (this.moodVisual === 'sleepy') { return 1.02; }
    return 1;
  }

  private eyeMoodY(): number {
    if (this.moodVisual === 'surprised') { return 1.14; }
    if (this.moodVisual === 'focused') { return 0.68; }
    if (this.moodVisual === 'happy') { return 0.98; }
    if (this.moodVisual === 'proud') { return 0.9; }
    if (this.moodVisual === 'curious') { return 1.02; }
    return 1;
  }

  private eyeScaleY(): number {
    return this.eyeHeight() * this.eyeMoodY();
  }

  private moodGazeX(): number {
    const gaze = this.attentionX + (this.scene !== 3 && this.moodVisual === 'curious' ? 3 : 0);
    return gaze * (1 - this.coverProgress) + this.peekProgress * 4;
  }

  private moodGazeY(): number {
    const gaze = this.attentionY + (this.scene !== 3 && this.moodVisual === 'curious' ? -2 : 0);
    return gaze * (1 - this.coverProgress) + this.peekProgress;
  }

  private moodTilt(): number {
    if (this.moodVisual === 'curious') { return 5; }
    if (this.moodVisual === 'focused') { return -3; }
    if (this.moodVisual === 'proud') { return -4; }
    if (this.moodVisual === 'sleepy') { return 2; }
    if (this.moodVisual === 'surprised') { return -1; }
    return 0;
  }

  // A short cream smile for the two warm moods; every shape is derived from diameter.
  private smileOpacity(): number {
    if (this.isSleepy() || this.coverEyes) { return 0; }
    if (this.moodVisual === 'proud') { return 0.9; }
    return this.moodVisual === 'happy' ? 1 : 0;
  }

  private smileScale(): number {
    return this.moodVisual === 'proud' ? 0.82 : 1;
  }

  private smilePath(): string {
    // Path commands use physical px, while component dimensions use vp.
    const ui = this.getUIContext();
    return `M ${ui.vp2px(this.unit(2))} ${ui.vp2px(this.unit(3))} ` +
      `Q ${ui.vp2px(this.unit(9))} ${ui.vp2px(this.unit(13))} ${ui.vp2px(this.unit(16))} ${ui.vp2px(this.unit(3))}`;
  }

  private bodyScaleX(): number {
    const base = (this.greeted ? 1.06 : 1) * (1 + this.sleepAmount() * 0.06 + this.sleepBreath());
    return this.feedback === 0 ? base * (1 + this.reaction * 0.025) : base;
  }

  private bodyScaleY(): number {
    const base = this.greeted ? 1.06 : 1;
    const sleepy = 1 - this.sleepAmount() * 0.1 - this.sleepBreath();
    return this.feedback === 0 ? base * sleepy * (1 + this.reaction * 0.025) : base * sleepy;
  }

  private bodyAngle(): number {
    const base = (this.greeted ? -9 : this.scene === 1 ? 5 * this.sleepAmount() : 0) +
      this.moodTilt() + this.sleepBreath() * 60;
    return this.feedback === 2 ? base + this.reaction * 7 : base;
  }

  private sparkScale(): number {
    const breathe = this.energized === true && this.isSleepy() !== true ?
      (Math.sin(this.phase * Math.PI * 2) + 1) / 2 * 0.08 * this.appearance.effectStrength : 0;
    return 1 - this.sleepAmount() * 0.22 + breathe;
  }

  private sparkOpacity(): number {
    if (this.sleepy === true) { return 0.3 + this.wakeProgress * 0.52; }
    if (this.energized !== true) { return 0.82; }
    const breathe = (Math.sin(this.phase * Math.PI * 2) + 1) / 2;
    return 0.7 + breathe * 0.22 * this.appearance.effectStrength;
  }

  private ink(): ResourceColor { return '#141413'; }

  private look(event: TouchEvent): void {
    if (event.type === TouchType.Down) { this.dragged = false; }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.gazeX = 0;
      this.gazeY = 0;
      return;
    }
    const point = event.touches[0];
    if (point) {
      const x = point.x * 220 / this.diameter;
      const y = point.y * 220 / this.diameter;
      this.gazeX = Math.max(-7, Math.min(7, (x - 110) / 12));
      this.gazeY = Math.max(-5, Math.min(5, (y - 110) / 15));
    }
  }

  private clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }

  private startDrag(event: GestureEvent): void {
    if (this.allowDrag !== true || this.active === false) { return; }
    this.dragging = true;
    this.settling = false;
    this.dragged = true;
    this.dragX = this.clamp(event.offsetX, -64, 64);
    this.dragY = this.clamp(event.offsetY, -44, 44);
  }

  private moveDrag(event: GestureEvent): void {
    if (!this.dragging) { return; }
    this.dragX = this.clamp(event.offsetX, -64, 64);
    this.dragY = this.clamp(event.offsetY, -44, 44);
  }

  private springBack(): void {
    this.dragging = false;
    this.settling = true;
    if (this.appearance.effectStrength === 0) {
      this.dragX = 0;
      this.dragY = 0;
      this.settling = false;
      return;
    }
    const revision = ++this.feedbackRevision;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.72), onFinish: () => {
      if (this.mounted && this.feedbackRevision === revision) { this.settling = false; }
    } }, () => {
      this.dragX = 0;
      this.dragY = 0;
    });
  }

  private endDrag(event: GestureEvent): void {
    if (!this.dragging) { return; }
    this.dragX = this.clamp(event.offsetX, -64, 64);
    this.dragY = this.clamp(event.offsetY, -44, 44);
    this.springBack();
  }

  private cancelDrag(): void {
    if (!this.dragging) { return; }
    this.springBack();
  }

  private react(): void {
    if (this.reacting || this.appearance.effectStrength === 0 || !this.mounted || !this.active || !this.foreground) { return; }
    this.reacting = true;
    const revision = ++this.feedbackRevision;
    this.tapCount = (this.tapCount + 1) % 3;
    this.feedback = this.tapCount;
    const ui = this.getUIContext();
    ui.animateTo({ duration: 110, curve: Curve.EaseOut, onFinish: () => {
      if (!this.mounted || this.feedbackRevision !== revision) { return; }
      ui.animateTo({ curve: curves.springMotion(0.36, 0.7), onFinish: () => {
        if (!this.mounted || this.feedbackRevision !== revision) { return; }
        this.reaction = 0;
        this.reacting = false;
      } }, () => { this.reaction = 0; });
    } }, () => { this.reaction = 1; });
  }

  private hello(): void {
    if (this.dragged) {
      this.dragged = false;
      return;
    }
    if (!this.mounted || this.active === false || !this.foreground) { return; }
    if (!this.sleepy && !this.coverEyes) { this.react(); }
    this.onHello();
  }

  @Builder
  sleepLetters() {
    ForEach([0, 1, 2], (index: number) => {
      Text(index === 2 ? 'Z' : 'z').fontFamily(this.appearance.fontFamily)
        .fontSize(this.unit(13 + index * 3)).fontWeight(FontWeight.Medium).fontColor(this.appearance.accent)
        .position({ x: this.unit(148 + this.sleepDrift(index) * 42),
          y: this.unit(70 - this.sleepDrift(index) * 64) })
        .opacity(Math.sin(this.sleepDrift(index) * Math.PI) * 0.7 * this.sleepAmount())
        .scale({ x: 0.75 + this.sleepDrift(index) * 0.25, y: 0.75 + this.sleepDrift(index) * 0.25 })
        .accessibilityLevel('no')
    }, (index: number) => index.toString())
  }

  @Builder
  hand(side: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      Rect().width(this.unit(28)).height(this.unit(40)).radius(this.unit(14))
        .fill('#F6E9D9').stroke('#CDBBA5').strokeWidth(this.unit(1))
      ForEach([0, 1], (finger: number) => {
        Line().width(this.unit(28)).height(this.unit(40))
          .startPoint([this.unit(9 + finger * 7), this.unit(8)])
          .endPoint([this.unit(9 + finger * 7), this.unit(18)])
          .stroke('#CDBBA5').strokeWidth(this.unit(1)).strokeLineCap(LineCapStyle.Round)
      }, (finger: number) => finger.toString())
    }.width(this.unit(28)).height(this.unit(40))
      .position({ x: this.unit(side === 0 ? 24 : 45), y: this.unit(29) })
      .translate({ x: this.unit(this.peekProgress * (side === 0 ? -4 : 12)),
        y: this.unit(54 * (1 - this.coverProgress)) })
      .rotate({ angle: (side === 0 ? -12 : 12) * (1 - this.peekProgress * 0.5) })
      .opacity(this.coverProgress).accessibilityLevel('no')
  }

  @Builder
  mark() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Circle().width(this.unit(134)).height(this.unit(134)).fill(this.ink())
          .stroke(this.dark ? $r('app.color.divider') : Color.Transparent).strokeWidth(this.unit(0.8))
        Circle().width(this.unit(29)).height(this.unit(29)).fill('#FFFFFF')
          .position({ x: this.unit(34 + this.gazeX + this.moodGazeX()),
            y: this.unit(34 + this.gazeY + this.moodGazeY()) })
          .scale({ x: this.eyeScaleX(), y: this.eyeScaleY() })
        Path().width(this.unit(18)).height(this.unit(12))
          .commands(this.smilePath())
          .fill(Color.Transparent).stroke('#FFFFFF').strokeWidth(this.unit(2.5)).strokeLineCap(LineCapStyle.Round)
          .position({ x: this.unit(78.5), y: this.unit(81.5) })
          .scale({ x: this.smileScale(), y: this.smileScale() })
          .opacity(this.smileOpacity())
        if (this.scene === 3) {
          this.hand(0)
          this.hand(1)
        }
      }.width(this.unit(134)).height(this.unit(134))
        .position({ x: this.unit(43), y: this.unit(43) })
        .translate({ y: this.lift() - this.unit(12) * (this.feedback === 0 ? this.reaction : 0) })
        .rotate({ angle: this.bodyAngle() })
        .scale({ x: this.bodyScaleX(), y: this.bodyScaleY() })
      Circle().width(this.unit(23)).height(this.unit(23)).fill('#D97B5B')
        .position({ x: this.unit(168), y: this.unit(22) })
        .translate({ y: -this.lift() * 0.7 })
        .scale({ x: this.sparkScale(), y: this.sparkScale() })
        .opacity(this.sparkOpacity())
      if (this.sleepy) {
        this.sleepLetters()
      }
      if (this.scene === 3 && this.connected) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(this.unit(19)).fontColor([this.appearance.onAccent])
        }.width(this.unit(38)).height(this.unit(38)).borderRadius(this.unit(19))
          .backgroundColor(this.appearance.accent).position({ x: this.unit(144), y: this.unit(132) })
          .translate({ y: this.lift() - this.unit(12) * (this.feedback === 0 ? this.reaction : 0) })
      }
    }.width(this.diameter).height(this.diameter).hitTestBehavior(HitTestMode.None)
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      this.mark()
    }.id('onboarding-mascot').width(this.diameter).height(this.diameter).padding(0)
      .backgroundColor(Color.Transparent).enabled(this.active !== false)
      .translate({ x: this.dragX, y: this.dragY })
      .accessibilityText(this.sleepy ? this.waking ? t('Tiny 正在醒来') : t('轻点叫醒 Tiny') : t('点点 Tinybot，打个招呼'))
      .accessibilityDescription(this.allowDrag ? t('可以拖动我，松手会回到这里。') : '')
      .onClick(() => this.hello())
      .onTouch((event: TouchEvent) => this.look(event))
      .onVisibleAreaChange([0, 1], (_isExpanding: boolean, ratio: number) => this.visibilityChanged(ratio))
      .gesture(PanGesture({ fingers: 1, isFingerCountLimited: true,
        direction: this.allowDrag ? PanDirection.All : PanDirection.None, distance: 4 })
        .onActionStart((event: GestureEvent) => this.startDrag(event))
        .onActionUpdate((event: GestureEvent) => this.moveDrag(event))
        .onActionEnd((event: GestureEvent) => this.endDrag(event))
        .onActionCancel(() => this.cancelDrag()))
  }
}
