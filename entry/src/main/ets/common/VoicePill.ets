import { AnimatorResult } from '@kit.ArkUI';
import { SpeechPhase } from '../services/SpeechInput';
import { t } from '../model/I18n';
import { Motion } from './Theme';
import { VoicePillAction, VoicePillGesture } from './VoicePillGesture';

// ArkUI interpretation of the supplied VoicePill: anchored capsule, clock and activity history.
@Component
export struct VoicePill {
  @Prop @Watch('syncPhase') phase: SpeechPhase = 'idle';
  @Prop speaking: boolean = false;
  @Prop startedAt: number = 0;
  @Prop @Watch('disabledChanged') disabled: boolean = false;
  onStart: () => void = () => {};
  onFinish: () => void = () => {};
  onCancel: () => void = () => {};
  @State private opened: boolean = false;
  @State private pressed: boolean = false;
  @State private pull: number = 0;
  @State private elapsed: string = '0:00';
  private gestureState: VoicePillGesture = new VoicePillGesture();
  private holdTimer: number = -1;
  private animator?: AnimatorResult;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private history: number[] = [];
  private level: number = 0;
  private lastFrame: number = 0;
  private lastSample: number = 0;
  private color: string = '247,250,248';

  aboutToDisappear(): void {
    clearTimeout(this.holdTimer); this.stopAnimation(); this.gestureState.reset(); this.ready = false;
  }

  private active(): boolean { return this.phase === 'preparing' || this.phase === 'listening' || this.phase === 'finishing'; }
  private disabledChanged(): void {
    if (this.disabled) {
      clearTimeout(this.holdTimer); this.gestureState.reset(); this.settle();
      if (this.active()) { this.onFinish(); }
    }
  }

  private syncPhase(): void {
    const active = this.active();
    this.getUIContext().animateTo({ duration: 200, curve: Motion.enter }, () => { this.opened = active; });
    if (!active) {
      clearTimeout(this.holdTimer); this.gestureState.reset();
      this.settle();
    }
    this.stopAnimation();
    this.history = []; this.level = 0; this.lastSample = 0; this.lastFrame = 0;
    if (!active) { this.elapsed = '0:00'; }
    if (!this.ready || !active) { return; }
    const animator = this.getUIContext().createAnimator({ duration: 1000, easing: 'linear', delay: 0,
      fill: 'none', direction: 'normal', iterations: -1, begin: 0, end: 1 });
    animator.onFrame = () => {
      if (this.animator !== animator) { return; }
      const now = Date.now();
      if (now - this.lastFrame < 32) { return; }
      const dt = Math.min(100, now - (this.lastFrame || now)); this.lastFrame = now;
      if (this.phase === 'listening' && this.startedAt) {
        const seconds = Math.max(0, Math.floor((now - this.startedAt) / 1000));
        const elapsed = Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
        if (elapsed !== this.elapsed) { this.elapsed = elapsed; }
      }
      this.draw(now, dt);
    };
    this.animator = animator; animator.play();
  }

  private stopAnimation(): void { const animator = this.animator; this.animator = undefined; animator?.cancel(); }

  private draw(now: number, dt: number): void {
    const ctx = this.canvas; const width = ctx.width; const height = ctx.height;
    if (width <= 0 || height <= 0) { return; }
    // Native capture exposes VAD events, not amplitude. Animate activity only while speech is detected.
    const target = this.phase === 'listening' && this.speaking ?
      0.35 + 0.65 * Math.abs(Math.sin(now / 137) * Math.cos(now / 89)) : 0;
    this.level += (target - this.level) * (1 - Math.exp(-dt / (target > this.level ? 40 : 240)));
    if (now - this.lastSample >= 80) {
      this.lastSample = now; this.history.push(this.level);
      if (this.history.length > 24) { this.history.shift(); }
    }
    ctx.clearRect(0, 0, width, height);
    ctx.lineWidth = 2; ctx.lineCap = 'round';
    const shift = Math.min(1, (now - this.lastSample) / 80) * 3;
    for (let i = 0; i < this.history.length; i++) {
      const level = this.history[this.history.length - 1 - i]; const x = width - 2 - i * 3 - shift;
      if (x < 0) { break; }
      const h = Math.max(2, level * (height - 2));
      ctx.strokeStyle = 'rgba(' + this.color + ',' + (Math.min(1, x / 22) * (0.4 + 0.6 * level)) + ')';
      ctx.beginPath(); ctx.moveTo(x, (height - h) / 2); ctx.lineTo(x, (height + h) / 2); ctx.stroke();
    }
  }

  private dispatch(action: VoicePillAction): void {
    if (action === 'start') { this.onStart(); }
    else if (action === 'finish') { this.onFinish(); }
    else if (action === 'cancel') { this.onCancel(); }
  }

  private settle(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Motion.standard }, () => { this.pressed = false; this.pull = 0; });
  }

  private touch(event: TouchEvent): void {
    if (this.disabled) { return; }
    const touch = event.changedTouches.find((item: TouchObject) => item.id === this.gestureState.pointer) || event.changedTouches[0];
    if (!touch) { return; }
    if (event.type === TouchType.Down) {
      if (!this.gestureState.down(touch.id, touch.screenX, this.active())) { return; }
      this.getUIContext().animateTo({ duration: 100, curve: Motion.standard }, () => { this.pressed = true; });
      this.holdTimer = setTimeout(() => this.dispatch(this.gestureState.hold()), 300);
    } else if (event.type === TouchType.Move) {
      const action = this.gestureState.move(touch.id, touch.screenX, this.active());
      this.pull = this.active() ? this.gestureState.pull : 0;
      this.dispatch(action);
    } else if (event.type === TouchType.Up && touch.id === this.gestureState.pointer) {
      clearTimeout(this.holdTimer);
      const action = this.gestureState.up(touch.id);
      this.settle(); this.dispatch(action);
    } else if (event.type === TouchType.Cancel && touch.id === this.gestureState.pointer) {
      clearTimeout(this.holdTimer);
      const action = this.gestureState.interrupt(); this.settle(); this.dispatch(action);
    }
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Stack({ alignContent: Alignment.End }) {
        Row({ space: 6 }) {
          Canvas(this.canvas).width(64).height(22).accessibilityLevel('no')
            .onReady(() => {
              this.ready = true;
              const value = this.getUIContext().getHostContext()!.resourceManager.getColorSync($r('app.color.on_accent').id);
              this.color = `${(value >>> 16) & 255},${(value >>> 8) & 255},${value & 255}`;
              this.syncPhase();
            })
          Text(this.elapsed).id('speech-time').width(34).fontSize(12).fontWeight(FontWeight.Medium)
            .fontFamily('monospace').fontColor($r('app.color.on_accent'))
          Blank().width(36)
        }.width(156).height(36).opacity(this.opened ? Math.max(0, 1 - this.pull / 64) : 0)
          .translate({ x: -this.pull * 0.45 }).hitTestBehavior(HitTestMode.None)
        Text('‹ ' + t('取消')).width(116).margin({ right: 36 }).fontSize(12)
          .fontColor($r('app.color.on_accent')).textAlign(TextAlign.Center).opacity(Math.min(1, this.pull / 64))
          .hitTestBehavior(HitTestMode.None)
        Stack() {
          SymbolGlyph($r('sys.symbol.mic')).fontSize(19).fontColor([$r('app.color.text_secondary')])
            .opacity(this.opened ? 0 : 1).scale({ x: this.opened ? 0.7 : 1, y: this.opened ? 0.7 : 1 })
          if (this.phase === 'preparing' || this.phase === 'finishing') {
            LoadingProgress().width(19).height(19).color($r('app.color.on_accent'))
          } else {
            Rect().width(10).height(10).radius(2).fill($r('app.color.on_accent'))
              .opacity(this.opened ? 1 : 0).scale({ x: this.opened ? 1 : 0.6, y: this.opened ? 1 : 0.6 })
          }
        }.width(36).height(36).translate({ x: -this.pull * 0.2 }).hitTestBehavior(HitTestMode.None)
      }.width('100%').height(36)
    }.id('start-speech').width(this.opened ? 156 : 36).height(36).padding(0).borderRadius(18).clip(true)
      .backgroundColor(this.opened ? $r('app.color.accent') : $r('app.color.surface_variant'))
      .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1, centerX: '100%', centerY: '50%' })
      .enabled(!this.disabled).opacity(this.disabled ? 0.4 : 1)
      .responseRegion({ x: 0, y: -4, width: '100%', height: 44 })
      .accessibilityText(this.active() ? t('停止语音输入') : t('语音转文字'))
      .accessibilityDescription(this.phase === 'preparing' ? t('正在准备语音识别…') : this.phase === 'finishing' ?
        t('正在整理识别文字…') : this.active() ? t('再次点击停止，左滑取消本次输入') : t('点击开始，或按住说话'))
      .onTouch((event: TouchEvent) => this.touch(event))
      .onClick((event: ClickEvent) => {
        // Pointer taps are handled above; keyboard and accessibility activation still work.
        if (event.source !== SourceType.TouchScreen) { this.dispatch(this.active() ? 'finish' : 'start'); }
      })
  }
}
