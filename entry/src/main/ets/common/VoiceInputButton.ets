import { AppearanceStyle } from './AppearanceStyle';
import { SpeechPhase } from '../services/SpeechInput';
import { t } from '../model/I18n';
import { Motion } from './Theme';

@Component
export struct VoiceInputButton {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('syncClock') phase: SpeechPhase = 'idle';
  @Prop @Watch('syncClock') startedAt: number = 0;
  @Prop @Watch('availabilityChanged') disabled: boolean = false;
  onStart: () => void = () => {};
  onFinish: () => void = () => {};
  @State private elapsed: string = '0:00';
  private clockTimer: number = -1;
  private mounted: boolean = false;

  aboutToAppear(): void { this.mounted = true; this.syncClock(); }
  aboutToDisappear(): void { this.mounted = false; clearTimeout(this.clockTimer); this.clockTimer = -1; }

  private active(): boolean {
    return this.phase === 'preparing' || this.phase === 'listening' || this.phase === 'finishing';
  }

  private availabilityChanged(): void {
    if (this.disabled && this.active() && this.phase !== 'finishing') { this.onFinish(); }
  }

  private syncClock(): void {
    clearTimeout(this.clockTimer); this.clockTimer = -1;
    if (!this.mounted) { return; }
    if (!this.active() || this.phase === 'preparing') { this.elapsed = '0:00'; }
    if (this.phase !== 'listening') { return; }
    const seconds = this.startedAt ? Math.max(0, Math.floor((Date.now() - this.startedAt) / 1000)) : 0;
    this.elapsed = Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
    this.clockTimer = setTimeout(() => this.syncClock(), 1000);
  }

  private activate(): void {
    if (this.disabled || this.phase === 'finishing') { return; }
    if (this.active()) { this.onFinish(); } else { this.onStart(); }
  }

  build() {
    Row({ space: 8 }) {
      if (this.active()) {
        Text(this.elapsed).id('speech-time').fontFamily('monospace').fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        if (this.phase === 'preparing' || this.phase === 'finishing') {
          LoadingProgress().width(19).height(19).color(this.appearance.onAccent)
        } else if (this.phase === 'listening') {
          Rect().width(10).height(10).radius(2).fill(this.appearance.onAccent)
        } else {
          SymbolGlyph($r('sys.symbol.mic')).fontSize(19).fontColor([$r('app.color.text_secondary')])
        }
      }.id('start-speech').width(36).height(36).padding(0).borderRadius(18)
        .backgroundColor(this.active() ? this.appearance.accent : $r('app.color.surface_variant'))
        .clickEffect(Motion.pressSmall).enabled(!this.disabled && this.phase !== 'finishing')
        .opacity(this.disabled ? 0.4 : 1).responseRegion({ x: -4, y: -4, width: 44, height: 44 })
        .accessibilityText(this.active() ? t('停止语音输入') : t('语音转文字'))
        .accessibilityDescription(this.phase === 'preparing' ? t('正在准备语音识别…') : this.phase === 'finishing' ?
          t('正在整理识别文字…') : this.active() ? t('再次点击结束语音输入') : t('点击麦克风开始录音'))
        .onClick(() => this.activate())
    }.height(36)
  }
}
