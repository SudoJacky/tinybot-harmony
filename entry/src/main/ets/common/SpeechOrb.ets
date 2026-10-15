import { AnimatorResult, ColorMetrics } from '@kit.ArkUI';
import { AppearanceStyle } from './AppearanceStyle';
import { SpeechPhase } from '../services/SpeechInput';
import { t } from '../model/I18n';

// Native visual feedback for system dictation. Speech detection is activity, not a volume meter.
@Component
export struct SpeechOrb {
  @StorageProp('tinybot.appearance.style') @Watch('syncAnimation') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncAnimation') private foreground: boolean = true;
  @Prop @Watch('syncAnimation') phase: SpeechPhase = 'idle';
  @Prop speaking: boolean = false;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private animator?: AnimatorResult;
  private ready: boolean = false;
  private visible: boolean = true;
  private lastFrame: number = 0;
  private born: number = Date.now();
  private activity: number = 0;
  private mainRgb: string = '33,100,81';
  private lowRgb: string = '36,74,58';
  private highRgb: string = '205,235,217';

  aboutToDisappear(): void { this.ready = false; this.stop(); }

  private active(): boolean {
    return this.phase === 'preparing' || this.phase === 'listening' || this.phase === 'finishing';
  }

  private stop(): void {
    const animator = this.animator; this.animator = undefined; animator?.cancel();
    this.lastFrame = 0;
  }

  private rgb(value: ResourceColor): string {
    const color = ColorMetrics.resourceColor(value);
    return `${color.red},${color.green},${color.blue}`;
  }

  private syncAnimation(): void {
    this.stop();
    if (!this.ready) { return; }
    this.mainRgb = this.rgb(this.appearance.accent);
    this.lowRgb = this.rgb(this.appearance.accentContainer);
    this.highRgb = this.rgb(this.appearance.onAccentContainer);
    this.draw(Date.now(), 0);
    if (!this.active() || !this.visible || !this.foreground || this.appearance.effectStrength === 0) { return; }
    const animator = this.getUIContext().createAnimator({ duration: 8000, easing: 'linear', delay: 0,
      fill: 'none', direction: 'normal', iterations: -1, begin: 0, end: 1 });
    animator.onFrame = (): void => {
      if (this.animator !== animator) { return; }
      const now = Date.now();
      if (this.lastFrame && now - this.lastFrame < 33) { return; }
      const dt = this.lastFrame ? Math.min(100, now - this.lastFrame) : 33;
      this.lastFrame = now;
      this.draw(now, dt);
    };
    this.animator = animator; animator.play();
  }

  private orbPath(x: number, y: number, radius: number, time: number, strength: number): void {
    const ctx = this.canvas;
    ctx.beginPath();
    for (let i = 0; i <= 64; i++) {
      const angle = i / 64 * Math.PI * 2;
      const ripple = (Math.sin(angle * 3 + time * 0.7) * 0.018 + Math.cos(angle * 5 - time * 0.4) * 0.012) * strength;
      const r = radius * (1 + ripple);
      const px = x + Math.cos(angle) * r; const py = y + Math.sin(angle) * r;
      if (i === 0) { ctx.moveTo(px, py); } else { ctx.lineTo(px, py); }
    }
    ctx.closePath();
  }

  private wash(x: number, y: number, radius: number, rgb: string, opacity: number): void {
    const ctx = this.canvas;
    const gradient = ctx.createRadialGradient(x, y, 0, x, y, radius);
    gradient.addColorStop(0, `rgba(${rgb},${opacity})`);
    gradient.addColorStop(0.55, `rgba(${rgb},${opacity * 0.5})`);
    gradient.addColorStop(1, `rgba(${rgb},0)`);
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, ctx.width, ctx.height);
  }

  private draw(now: number, dt: number): void {
    const ctx = this.canvas; const width = ctx.width; const height = ctx.height;
    if (width <= 0 || height <= 0) { return; }
    ctx.clearRect(0, 0, width, height);
    if (!this.active()) { return; }
    const strength = this.appearance.effectStrength;
    const target = this.phase === 'listening' && this.speaking ? 1 : 0;
    this.activity += (target - this.activity) * (1 - Math.exp(-dt / (target > this.activity ? 100 : 350)));
    const time = strength === 0 ? 0 : (now - this.born) / 1000;
    const motion = strength * (this.phase === 'listening' ? 0.55 + this.activity * 0.45 : 0.3);
    const x = width / 2; const y = height / 2;
    const radius = Math.min(width, height) * 0.34 * (1 + Math.sin(time * 1.8) * 0.018 * motion);
    this.wash(x, y, radius * 1.43, this.mainRgb, 0.12);
    ctx.save();
    this.orbPath(x, y, radius, time, motion);
    ctx.clip();
    const base = ctx.createLinearGradient(x - radius, y - radius, x + radius, y + radius);
    base.addColorStop(0, `rgb(${this.lowRgb})`);
    base.addColorStop(0.5, `rgb(${this.mainRgb})`);
    base.addColorStop(1, `rgb(${this.highRgb})`);
    ctx.fillStyle = base; ctx.fillRect(0, 0, width, height);
    // Overlapping soft fields suggest a liquid interior without shaders or per-pixel work.
    this.wash(x + Math.sin(time * 0.6) * radius * 0.35 * motion,
      y - radius * 0.38 + Math.cos(time * 0.5) * radius * 0.2 * motion, radius * 1.05, '176,224,255', 0.78);
    this.wash(x - radius * 0.5 + Math.cos(time * 0.45) * radius * 0.3 * motion,
      y + radius * 0.25, radius * 0.94, this.lowRgb, 0.88);
    this.wash(x + radius * 0.48, y + Math.sin(time * 0.55) * radius * 0.42 * motion,
      radius * 0.82, '184,160,244', 0.43);
    this.wash(x - radius * 0.27, y - radius * 0.5, radius * 0.7, '255,255,255', 0.45);
    ctx.restore();
    this.orbPath(x, y, radius, time, motion);
    ctx.strokeStyle = `rgba(${this.mainRgb},0.22)`; ctx.lineWidth = 0.8; ctx.stroke();
  }

  private label(): string {
    return this.phase === 'preparing' ? t('正在准备语音识别…') :
      this.phase === 'finishing' ? t('正在整理识别文字…') : t('正在聆听…');
  }

  build() {
    Column({ space: 0 }) {
      Canvas(this.canvas).id('speech-orb').width(144).height(112).accessibilityLevel('no')
        .hitTestBehavior(HitTestMode.None)
        .onReady(() => { this.ready = true; this.syncAnimation(); })
        .onAreaChange(() => { if (this.ready) { this.draw(Date.now(), 0); } })
        .onVisibleAreaChange([0], (visible: boolean) => { this.visible = visible; this.syncAnimation(); })
      Text(this.label()).fontFamily(this.appearance.fontFamily).id('speech-orb-status').fontSize(14)
        .fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center).width('100%')
    }.id('speech-orb-panel').width('100%').padding({ top: 2, bottom: 10 })
  }
}
