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
  @Prop @Watch('farewellChanged') farewell: boolean = false;
  @Prop @Watch('speechChanged') speechLine: number = -1;
  @Prop @Watch('dreamChanged') dream: boolean = false;
  @Prop @Watch('keyInputChanged') keyStroke: number = 0;
  @Prop diameter: number = 220;
  @Prop @Watch('wakeChanged') sleepy: boolean = false;
  @Prop @Watch('wakeChanged') waking: boolean = false;
  @Prop energized: boolean = false;
  @Prop allowDrag: boolean = false;
  @Prop @Watch('connectedChanged') connected: boolean = false;
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
  @State private blink: number = 0;
  @State private idleX: number = 0;
  @State private idleY: number = 0;
  @State private wakeBeat: number = 0;
  @State private checkProgress: number = 0;
  @State private sparkX: number = 0;
  @State private sparkY: number = 0;
  @State private sparkReaction: number = 0;
  private feedback: number = 0;
  private tapCount: number = 0;
  private mounted: boolean = false;
  private visible: boolean = false;
  private playing: boolean = false;
  @State private dragging: boolean = false;
  private settling: boolean = false;
  private dragged: boolean = false;
  private reacting: boolean = false;
  private feedbackRevision: number = 0;
  private peekTimer: number = -1;
  private peekRevision: number = 0;
  private animator?: AnimatorResult;
  private blinkTimer: number = -1;
  private glanceTimer: number = -1;
  private idleRevision: number = 0;
  private glanceRevision: number = 0;
  private wakeTimers: number[] = [];
  private wakeRevision: number = 0;

  aboutToAppear(): void {
    this.mounted = true;
    this.moodVisual = this.mood;
    this.wakeProgress = this.waking ? 1 : 0;
    this.attentionX = this.lookX;
    this.attentionY = this.lookY;
    this.coverProgress = this.coverEyes ? 1 : 0;
    this.checkProgress = this.connected ? 1 : 0;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.cancelPeek();
    this.cancelIdle();
    this.cancelWakeMotion();
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
    if (next === 'oops') { this.react(2); }
  }

  private syncPlayback(): void {
    const unavailable = this.active === false || !this.foreground || !this.visible;
    if (unavailable || this.appearance.effectStrength === 0) {
      this.cancelPeek();
      this.cancelIdle();
      this.cancelWakeMotion();
      this.wakeProgress = this.waking ? 1 : 0;
      this.wakeBeat = this.waking ? 7 : 0;
      this.sparkX = 0; this.sparkY = 0; this.sparkReaction = 0;
      this.checkProgress = this.connected ? 1 : 0;
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
    this.scheduleBlink();
    this.scheduleGlance();
    if (this.coverEyes) { this.coverChanged(); }
  }

  private attentionChanged(): void {
    this.resetAttention();
    const change = (): void => { this.attentionX = this.lookX; this.attentionY = this.lookY; };
    if (!this.mounted || !this.playing || this.appearance.effectStrength === 0) { change(); return; }
    this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseInOut }, change);
  }

  private cancelPeek(): void {
    this.peekRevision++;
    if (this.peekTimer >= 0) { clearTimeout(this.peekTimer); this.peekTimer = -1; }
  }

  private coverChanged(): void { this.resetCover(850); }

  private resetCover(delay: number): void {
    this.cancelPeek();
    const change = (): void => {
      this.coverProgress = this.coverEyes ? 1 : 0;
      this.peekProgress = 0;
    };
    if (!this.mounted || !this.playing || this.appearance.effectStrength === 0) { change(); return; }
    this.getUIContext().animateTo({ duration: this.coverEyes && this.peekProgress > 0 ? 120 : 280,
      curve: Curve.EaseOut }, change);
    if (!this.coverEyes) { return; }
    const revision = this.peekRevision;
    this.peekTimer = setTimeout(() => {
      if (!this.mounted || !this.playing || !this.coverEyes || revision !== this.peekRevision) { return; }
      this.peekTimer = -1;
      this.getUIContext().animateTo({ duration: 440, curve: Curve.EaseInOut }, () => { this.peekProgress = 1; });
    }, delay);
  }

  private keyInputChanged(): void {
    if (this.coverEyes) { this.resetCover(1000); }
  }

  private connectedChanged(): void {
    if (!this.mounted || !this.playing) { this.checkProgress = this.connected ? 1 : 0; return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.65) }, () => {
      this.checkProgress = this.connected ? 1 : 0;
    });
    if (this.connected) { this.react(0); }
  }

  private farewellChanged(): void { if (this.farewell) { this.react(0); } }
  private speechChanged(): void { if (this.speechLine >= 0) { this.react(this.speechLine === 0 ? 3 : 4); } }
  private dreamChanged(): void { if (this.dream && this.sleepy) { this.react(1); } }

  private cancelIdle(): void {
    this.idleRevision++;
    if (this.blinkTimer >= 0) { clearTimeout(this.blinkTimer); this.blinkTimer = -1; }
    if (this.glanceTimer >= 0) { clearTimeout(this.glanceTimer); this.glanceTimer = -1; }
    this.blink = 0; this.idleX = 0; this.idleY = 0;
  }

  private scheduleBlink(delay: number = 2500 + Math.random() * 3500, second: boolean = false): void {
    if (!this.mounted || !this.playing) { return; }
    const revision = this.idleRevision;
    this.blinkTimer = setTimeout(() => {
      if (revision !== this.idleRevision || !this.mounted || !this.playing) { return; }
      this.blinkTimer = -1;
      if (this.sleepy || this.coverEyes || this.waking) { this.scheduleBlink(); return; }
      const ui = this.getUIContext();
      ui.animateTo({ duration: 85, curve: Curve.EaseInOut, onFinish: () => {
        if (revision !== this.idleRevision || !this.mounted || !this.playing) { return; }
        ui.animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.blink = 0; });
        if (!second && Math.random() < 0.18) { this.scheduleBlink(220, true); }
        else { this.scheduleBlink(); }
      } }, () => { this.blink = 1; });
    }, delay);
  }

  private resetAttention(): void {
    this.glanceRevision++;
    if (this.glanceTimer >= 0) { clearTimeout(this.glanceTimer); this.glanceTimer = -1; }
    this.idleX = 0; this.idleY = 0;
    this.scheduleGlance();
  }

  private scheduleGlance(returning: boolean = false): void {
    if (!this.mounted || !this.playing) { return; }
    const revision = this.idleRevision;
    const glanceRevision = this.glanceRevision;
    this.glanceTimer = setTimeout(() => {
      if (revision !== this.idleRevision || glanceRevision !== this.glanceRevision || !this.mounted || !this.playing) { return; }
      this.glanceTimer = -1;
      if (this.sleepy || this.waking || this.coverEyes || this.dragging || this.reacting || this.lookX !== 0 || this.lookY !== 0) {
        this.scheduleGlance(); return;
      }
      this.getUIContext().animateTo({ duration: 360, curve: Curve.EaseInOut }, () => {
        this.idleX = returning ? 0 : (Math.random() < 0.5 ? -5 : 5);
        this.idleY = returning ? 0 : -2;
      });
      this.scheduleGlance(!returning);
    }, returning ? 1000 : 8000 + Math.random() * 4000);
  }

  private unit(value: number): number { return value * this.diameter / 220; }

  private wakeChanged(): void {
    this.cancelWakeMotion();
    if (!this.mounted || !this.playing || !this.waking || this.appearance.effectStrength === 0) {
      this.wakeProgress = this.waking ? 1 : 0;
      this.wakeBeat = this.waking ? 7 : 0;
      return;
    }
    const revision = this.wakeRevision;
    this.wakeProgress = 0;
    this.playWakeBeat(1);
    [150, 300, 450, 800, 1050, 1300].forEach((delay: number, index: number) => {
      this.wakeTimers.push(setTimeout(() => {
        if (revision !== this.wakeRevision || !this.mounted || !this.playing || !this.waking) { return; }
        this.playWakeBeat(index + 2);
      }, delay));
    });
  }

  private cancelWakeMotion(): void {
    this.wakeRevision++;
    this.wakeTimers.forEach((timer: number) => clearTimeout(timer));
    this.wakeTimers = [];
  }

  private playWakeBeat(beat: number): void {
    this.getUIContext().animateTo({ duration: beat < 4 ? 120 : 280,
      curve: beat === 4 ? curves.springMotion(0.32, 0.66) : Curve.EaseInOut }, () => {
      this.wakeBeat = beat;
      this.wakeProgress = beat === 2 ? 0.38 : beat < 4 ? 0 : 1;
    });
  }

  private expression(): string {
    if (this.dragging) { return 'surprised'; }
    if (this.waking) { return this.wakeBeat >= 7 ? 'happy' : this.wakeBeat >= 4 ? 'surprised' : 'sleepy'; }
    return this.moodVisual;
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
    if (this.sleepy === true) { return 0.12 + this.wakeProgress * 0.88 + (this.dream && this.feedback === 1 ? this.reaction * 0.2 : 0); }
    if (this.expression() === 'sleepy') { return 0.3; }
    if (this.appearance.effectStrength === 0) { return 1; }
    if (this.feedback === 1) { return 1 - this.reaction * 0.92; }
    return 1 - this.blink * 0.9;
  }

  private isSleepy(): boolean {
    return this.sleepAmount() > 0.5 || this.expression() === 'sleepy';
  }

  // The eye keeps its base diameter and node; mood only changes its transform.
  private eyeScaleX(): number {
    if (this.expression() === 'surprised') { return 1.18; }
    if (this.expression() === 'focused') { return 1.03; }
    if (this.expression() === 'happy') { return 1.06; }
    if (this.expression() === 'proud') { return 1.02; }
    if (this.expression() === 'curious') { return 1.04; }
    if (this.expression() === 'sleepy') { return 1.02; }
    return 1;
  }

  private eyeMoodY(): number {
    if (this.expression() === 'oops') { return 0.78; }
    if (this.expression() === 'surprised') { return 1.14; }
    if (this.expression() === 'focused') { return 0.68; }
    if (this.expression() === 'happy') { return 0.98; }
    if (this.expression() === 'proud') { return 0.9; }
    if (this.expression() === 'curious') { return 1.02; }
    return 1;
  }

  private eyeScaleY(): number {
    return this.eyeHeight() * this.eyeMoodY();
  }

  private moodGazeX(): number {
    const gaze = this.attentionX + this.idleX + (this.waking ? this.wakeBeat === 5 ? -7 : this.wakeBeat === 6 ? 7 : 0 : 0) + (this.scene !== 3 && this.expression() === 'curious' ? 3 : 0);
    return gaze * (1 - this.coverProgress) + this.peekProgress * 4;
  }

  private moodGazeY(): number {
    const gaze = this.attentionY + this.idleY + (this.expression() === 'focused' ? 3 : 0) + (this.scene !== 3 && this.expression() === 'curious' ? -2 : 0);
    return gaze * (1 - this.coverProgress) + this.peekProgress;
  }

  private moodTilt(): number {
    if (this.expression() === 'oops') { return -7; }
    if (this.expression() === 'curious') { return 5; }
    if (this.expression() === 'focused') { return -3; }
    if (this.expression() === 'proud') { return -4; }
    if (this.expression() === 'sleepy') { return 2; }
    if (this.expression() === 'surprised') { return -1; }
    return 0;
  }

  // A short cream smile for the two warm moods; every shape is derived from diameter.
  private smileOpacity(): number {
    if (this.isSleepy() || this.coverEyes) { return 0; }
    if (this.expression() === 'proud') { return 0.9; }
    return this.expression() === 'happy' ? 1 : 0;
  }

  private smileScale(): number {
    return this.expression() === 'proud' ? 0.82 : 1;
  }

  private smilePath(): string {
    // Path commands use physical px, while component dimensions use vp.
    const ui = this.getUIContext();
    return `M ${ui.vp2px(this.unit(2))} ${ui.vp2px(this.unit(3))} ` +
      `Q ${ui.vp2px(this.unit(9))} ${ui.vp2px(this.unit(13))} ${ui.vp2px(this.unit(16))} ${ui.vp2px(this.unit(3))}`;
  }

  private bodyScaleX(): number {
    const base = (1 + this.sleepAmount() * 0.06 + this.sleepBreath()) *
      (1 + Math.abs(this.dragX) / 800) * (this.waking && this.wakeBeat === 1 ? 1.08 : 1);
    return base * (1 + this.reaction * (this.feedback === 4 ? 0.025 : this.feedback === 3 ? 0.05 : 0.025));
  }

  private bodyScaleY(): number {
    const base = (1 + Math.abs(this.dragY) / 550) * (this.waking && this.wakeBeat === 1 ? 0.92 : 1);
    const sleepy = 1 - this.sleepAmount() * 0.1 - this.sleepBreath();
    return base * sleepy * (1 + this.reaction * (this.feedback === 4 ? -0.035 : this.feedback === 3 ? 0.05 : 0.025));
  }

  private bodyAngle(): number {
    const base = (this.feedback === 3 ? -9 * this.reaction : this.scene === 1 ? 5 * this.sleepAmount() : 0) + this.dragX * 0.08 +
      this.moodTilt() + this.sleepBreath() * 60;
    return this.feedback === 2 ? base + this.reaction * 7 : base;
  }

  private sparkScale(): number {
    const breathe = this.energized === true && this.isSleepy() !== true ?
      (Math.sin((this.phase + 0.18) * Math.PI * 2) + 1) / 2 * 0.08 * this.appearance.effectStrength : 0;
    return 1 - this.sleepAmount() * 0.22 + breathe + (this.connected ? this.sparkReaction * 0.18 : 0);
  }

  private sparkOpacity(): number {
    if (this.sleepy === true) { return 0.3 + this.wakeProgress * 0.52; }
    if (this.energized !== true) { return 0.82; }
    const breathe = (Math.sin((this.phase + 0.18) * Math.PI * 2) + 1) / 2;
    return Math.min(1, 0.84 + breathe * 0.16 * this.appearance.effectStrength + this.sparkReaction * 0.16);
  }

  private ink(): ResourceColor { return '#141413'; }

  private look(event: TouchEvent): void {
    if (event.type === TouchType.Down) { this.dragged = false; this.resetAttention(); }
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
    this.followSpark();
  }

  private moveDrag(event: GestureEvent): void {
    if (!this.dragging) { return; }
    this.dragX = this.clamp(event.offsetX, -64, 64);
    this.dragY = this.clamp(event.offsetY, -44, 44);
    this.followSpark();
  }

  private springBack(): void {
    this.settling = true;
    if (this.appearance.effectStrength === 0) {
      this.dragging = false;
      this.dragX = 0;
      this.dragY = 0;
      this.settling = false;
      this.followSpark();
      return;
    }
    const revision = ++this.feedbackRevision;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.72), onFinish: () => {
      if (this.mounted && this.feedbackRevision === revision) { this.settling = false; }
    } }, () => {
      this.dragging = false;
      this.dragX = 0;
      this.dragY = 0;
    });
    this.followSpark();
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

  private followSpark(): void {
    const change = (): void => { this.sparkX = this.dragX; this.sparkY = this.dragY; this.sparkReaction = this.reaction; };
    if (!this.playing || this.appearance.effectStrength === 0) { change(); return; }
    this.getUIContext().animateTo({ delay: 60, curve: curves.springMotion(0.55, 0.68) }, change);
  }

  private react(kind: number = -1): void {
    if ((this.reacting && kind < 0) || this.appearance.effectStrength === 0 || !this.mounted || !this.playing || !this.active || !this.foreground) { return; }
    this.resetAttention();
    this.reacting = true;
    const revision = ++this.feedbackRevision;
    this.tapCount = (this.tapCount + 1) % 3;
    this.feedback = kind >= 0 ? kind : this.tapCount;
    const ui = this.getUIContext();
    ui.animateTo({ duration: 110, curve: Curve.EaseOut, onFinish: () => {
      if (!this.mounted || this.feedbackRevision !== revision) { return; }
      ui.animateTo({ curve: curves.springMotion(0.36, 0.7), onFinish: () => {
        if (!this.mounted || this.feedbackRevision !== revision) { return; }
        this.reaction = 0;
        this.reacting = false;
      } }, () => { this.reaction = 0; });
      this.followSpark();
    } }, () => { this.reaction = 1; });
    this.followSpark();
  }

  private hello(): void {
    if (this.dragged) {
      this.dragged = false;
      return;
    }
    if (!this.mounted || this.active === false || !this.foreground) { return; }
    if (!this.isSleepy() && !this.coverEyes) { this.react(3); }
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
        .translate({ y: this.lift() - this.unit(12) * (this.feedback === 0 ? this.reaction : 0) -
          this.unit(this.waking && this.wakeBeat === 4 ? 14 : 0) })
        .rotate({ angle: this.bodyAngle() })
        .scale({ x: this.bodyScaleX(), y: this.bodyScaleY() })
      Circle().width(this.unit(23)).height(this.unit(23)).fill($r('app.color.tiny_coral'))
        .position({ x: this.unit(168), y: this.unit(22) })
        .translate({ x: this.sparkX - this.dragX, y: this.sparkY - this.dragY - this.lift() * 0.7 -
          this.unit(8) * (this.feedback === 0 ? this.sparkReaction : 0) })
        .scale({ x: this.sparkScale(), y: this.sparkScale() })
        .opacity(this.sparkOpacity())
      if (this.sleepy) {
        this.sleepLetters()
      }
      if (this.scene === 3) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(this.unit(19)).fontColor([this.appearance.onAccent])
        }.width(this.unit(38)).height(this.unit(38)).borderRadius(this.unit(19))
          .backgroundColor(this.appearance.accent).position({ x: this.unit(144), y: this.unit(132) })
          .translate({ y: this.lift() - this.unit(12) * (this.feedback === 0 ? this.reaction : 0) })
          .scale({ x: this.checkProgress, y: this.checkProgress }).opacity(this.checkProgress)
      }
    }.width(this.diameter).height(this.diameter).hitTestBehavior(HitTestMode.None)
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      this.mark()
    }.id('onboarding-mascot').width(this.diameter).height(this.diameter).padding(0)
      .backgroundColor(Color.Transparent).enabled(this.active !== false)
      .translate({ x: this.dragX, y: this.dragY })
      .accessibilityText(this.sleepy ? this.scene === 0 ? t('Tiny 正在休息') :
        this.waking ? t('Tiny 正在醒来') : t('轻点叫醒 Tiny') : t('点点 Tinybot，打个招呼'))
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
