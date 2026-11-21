import { AnimatorResult } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';

const RIBBON_COUNT: number = 108;
const BURST_COUNT: number = 36;
const TAP_RIBBON_COUNT: number = 24;
const MAX_TAP_BURSTS: number = 6;
const TAP_BURST_DURATION_MS: number = 1350;
const FRAME_INTERVAL_MS: number = 32;
const PALETTE: string[] = ['#FFD572', '#F59176', '#95DFB8', '#D6B8F5', '#FFEDD2', '#8ACEF5'];

interface Ribbon {
  column: number;
  offset: number;
  fallSpeed: number;
  sway: number;
  turn: number;
  flutter: number;
  phase: number;
  width: number;
  length: number;
  color: string;
}

export interface ConfettiPoint {
  x: number;
  y: number;
}

interface TapBurst {
  point: ConfettiPoint;
  startedAt: number;
  rotation: number;
}

@Component
export struct OnboardingConfetti {
  @StorageProp('tinybot.appearance.style') @Watch('syncPlayback') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncPlayback') private foreground: boolean = true;
  @Prop @Watch('syncPlayback') active: boolean = false;
  @Prop @Watch('onTap') tap: ConfettiPoint = { x: 0, y: 0 };
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private animator?: AnimatorResult;
  private tapBursts: TapBurst[] = [];
  private ready: boolean = false;
  private visible: boolean = false;

  aboutToDisappear(): void {
    this.ready = false;
    this.stop();
  }

  private clear(): void { this.canvas.clearRect(0, 0, this.canvas.width, this.canvas.height); }

  private stop(): void {
    const animator = this.animator;
    this.animator = undefined;
    this.tapBursts.length = 0;
    if (animator) { animator.cancel(); this.clear(); }
  }

  private syncPlayback(): void {
    if (!this.ready || !this.visible || !this.active || !this.foreground || this.appearance.effectStrength === 0) {
      this.stop(); return;
    }
    if (this.animator || this.canvas.width <= 0 || this.canvas.height <= 0) { return; }

    const ribbons = this.makeRibbons();
    const started = Date.now();
    let lastFrame = started - FRAME_INTERVAL_MS;
    const animator = this.getUIContext().createAnimator({ duration: 1000, easing: 'linear', delay: 0,
      fill: 'none', direction: 'normal', iterations: -1, begin: 0, end: 1 });
    animator.onFrame = (): void => {
      if (this.animator !== animator) { return; }
      const now = Date.now();
      if (now - lastFrame < FRAME_INTERVAL_MS) { return; }
      lastFrame = now;
      this.draw(ribbons, (now - started) / 1000);
      this.drawTapBursts(ribbons, now);
    };
    this.animator = animator;
    animator.play();
  }

  private makeRibbons(): Ribbon[] {
    const ribbons: Ribbon[] = [];
    for (let index = 0; index < RIBBON_COUNT; index++) {
      ribbons.push({ column: (index + Math.random()) / RIBBON_COUNT, offset: (index * 0.618 + Math.random() * 0.2) % 1,
        fallSpeed: 29 + Math.random() * 15, sway: 7 + Math.random() * 12,
        turn: (Math.random() - 0.5) * 3.2, flutter: 5 + Math.random() * 7, phase: Math.random() * 2 * Math.PI,
        width: 2.4 + Math.random() * 2.6, length: 5 + Math.random() * 10, color: PALETTE[index % PALETTE.length] });
    }
    return ribbons;
  }

  private draw(ribbons: Ribbon[], elapsed: number): void {
    const ctx = this.canvas;
    const width = ctx.width;
    const height = ctx.height;
    const fallDistance = height + 32;
    this.clear();
    const fadeIn = Math.min(1, elapsed * 1.8);
    for (const ribbon of ribbons) {
      // Each strip exits below the card and re-enters above its clipped edge.
      const x = width * ribbon.column + Math.sin(elapsed * 1.6 + ribbon.phase) * ribbon.sway;
      const y = (fallDistance * ribbon.offset + elapsed * ribbon.fallSpeed) % fallDistance - 16;
      this.paint(ribbon, x, y, elapsed, fadeIn * 0.9);
    }

    // A short side burst welcomes the user before the slower shower takes over.
    for (let index = 0; index < BURST_COUNT && elapsed < 2.55; index++) {
      const ribbon = ribbons[index];
      const age = (elapsed - ribbon.offset * 0.24) / 1.4;
      if (age <= 0 || age >= 1.65) { continue; }
      const travel = (0.58 + ribbon.offset * 0.78) * (1 - Math.exp(-1.55 * age)) / 1.55;
      const x = width * (index % 2 === 0 ? 0.025 + travel : 0.975 - travel);
      const y = height * 0.86 + Math.min(height, 174) * (-(1.86 + ribbon.offset * 1.1) * age + 2.2 * age * age);
      this.paint(ribbon, x, y, age, Math.min(1, age * 26, (1.65 - age) * 4));
    }
  }

  private onTap(): void {
    if (!this.animator) { return; }
    if (this.tapBursts.length >= MAX_TAP_BURSTS) { this.tapBursts.shift(); }
    this.tapBursts.push({ point: this.tap, startedAt: Date.now(), rotation: Math.random() * 2 * Math.PI });
  }

  private drawTapBursts(ribbons: Ribbon[], now: number): void {
    while (this.tapBursts.length > 0 && now - this.tapBursts[0].startedAt >= TAP_BURST_DURATION_MS) {
      this.tapBursts.shift();
    }
    for (const burst of this.tapBursts) {
      const age = (now - burst.startedAt) / 1000;
      const travel = (1 - Math.exp(-2.8 * age)) / 2.8;
      const drop = 72 * age * age - 22 * travel;
      const opacity = Math.min(1, (TAP_BURST_DURATION_MS / 1000 - age) * 4);
      for (let index = 0; index < TAP_RIBBON_COUNT; index++) {
        const ribbon = ribbons[index];
        const angle = burst.rotation + (index + ribbon.offset * 0.6) * 2 * Math.PI / TAP_RIBBON_COUNT;
        const distance = (110 + ribbon.offset * 165) * travel;
        this.paint(ribbon, burst.point.x + Math.cos(angle) * distance,
          burst.point.y + Math.sin(angle) * distance + drop, age, opacity);
      }
    }
  }

  private paint(ribbon: Ribbon, x: number, y: number, time: number, opacity: number): void {
    const ctx = this.canvas;
    if (x < -16 || x > ctx.width + 16 || y < -16 || y > ctx.height + 16) { return; }
    const flip = 0.24 + 0.76 * Math.abs(Math.cos(time * ribbon.flutter + ribbon.phase));
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(ribbon.phase + ribbon.turn * time + 0.42 * Math.sin(time * 3 + ribbon.phase));
    ctx.globalAlpha = opacity * (0.72 + 0.28 * flip);
    ctx.fillStyle = ribbon.color;
    ctx.fillRect(-ribbon.width * flip / 2, -ribbon.length / 2, ribbon.width * flip, ribbon.length);
    ctx.restore();
  }

  build() {
    Canvas(this.canvas).id('onboarding-confetti').width('100%').height('100%')
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .onReady(() => { this.ready = true; this.syncPlayback(); })
      .onAreaChange(() => this.syncPlayback())
      .onVisibleAreaChange([0.25], (visible: boolean) => { this.visible = visible; this.syncPlayback(); })
  }
}
