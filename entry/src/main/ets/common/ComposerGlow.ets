import { AnimatorResult } from '@kit.ArkUI';
import { Radius } from './Theme';

// Original ArkUI decoration: a soft lower wash and a small, deterministic star field.
// Canvas keeps animation updates out of the input and message component trees.
@Component
export struct ComposerGlow {
  @Prop @Watch('syncAnimation') active: boolean = false;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private animator?: AnimatorResult;
  private ready: boolean = false;
  private visible: boolean = false;
  private phase: number = 0;
  private lastFrame: number = 0;
  private bubbleRgb: string = '217, 236, 225';
  private particleRgb: string = '33, 100, 81';

  aboutToDisappear(): void {
    this.ready = false;
    this.stop();
  }

  private stop(): void {
    this.animator?.cancel();
    this.animator = undefined;
  }

  private syncAnimation(): void {
    this.stop();
    if (!this.ready) return;
    try {
      const resources = this.getUIContext().getHostContext()!.resourceManager;
      this.bubbleRgb = this.rgb(resources.getColorSync($r('app.color.user_bubble').id));
      this.particleRgb = this.rgb(resources.getColorSync($r('app.color.accent').id));
    } catch (_) { /* Keep the default chat palette if resources are unavailable. */ }
    this.draw();
    if (!this.active || !this.visible) return;
    const animator = this.getUIContext().createAnimator({ duration: 6000, easing: 'linear', delay: 0,
      fill: 'none', direction: 'normal', iterations: -1, begin: 0, end: 1 });
    animator.onFrame = (phase: number): void => {
      const now = Date.now();
      if (now - this.lastFrame < 32) return;
      this.lastFrame = now; this.phase = phase; this.draw();
    };
    this.animator = animator;
    animator.play();
  }

  private rgb(value: number): string {
    return `${(value >>> 16) & 255}, ${(value >>> 8) & 255}, ${value & 255}`;
  }

  private draw(): void {
    const ctx = this.canvas; const width = ctx.width; const height = ctx.height;
    if (width <= 0 || height <= 0) return;
    ctx.clearRect(0, 0, width, height);
    if (!this.active) return;
    // Elliptical glow stays under the toolbar, fading before the writing area.
    ctx.save();
    ctx.scale(width, height);
    const wash = ctx.createRadialGradient(0.24, 1.08, 0, 0.24, 1.08, 0.95);
    wash.addColorStop(0, `rgba(${this.bubbleRgb}, 0.85)`);
    wash.addColorStop(0.5, `rgba(${this.bubbleRgb}, 0.30)`);
    wash.addColorStop(1, `rgba(${this.bubbleRgb}, 0)`);
    ctx.fillStyle = wash; ctx.fillRect(0, 0, 1, 1); ctx.restore();
    for (let i = 0; i < 24; i++) {
      const progress = (this.phase + i * 0.381966) % 1;
      const x = (0.03 + ((i * 0.173) % 0.91)) * width + Math.sin(progress * Math.PI * 2 + i) * 5;
      const y = height - 5 - progress * 57;
      const opacity = Math.sin(progress * Math.PI) * (0.28 + (i % 3) * 0.12);
      const radius = 0.7 + (i % 3) * 0.35;
      ctx.fillStyle = `rgba(${this.particleRgb}, ${opacity})`;
      ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2); ctx.fill();
    }
  }

  build() {
    Canvas(this.canvas).id('composer-effort-glow').width('100%').height(96)
      .borderRadius(Radius.xl).clip(true).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .onReady(() => { this.ready = true; this.syncAnimation(); })
      .onAreaChange(() => { if (this.ready) this.draw(); })
      .onVisibleAreaChange([0], (visible: boolean) => { this.visible = visible; this.syncAnimation(); })
  }
}
