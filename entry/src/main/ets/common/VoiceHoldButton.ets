import { AppearanceStyle } from './AppearanceStyle';
import { Motion } from './Theme';
import { t } from '../model/I18n';
import { VoiceAction } from '../model/VoiceGesture';
import { SpeechPhase } from '../services/SpeechInput';

@Component
export struct VoiceHoldButton {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('availabilityChanged') disabled: boolean = false;
  @Prop @Watch('phaseChanged') phase: SpeechPhase = 'idle';
  @Prop action: VoiceAction = 'send';
  onHold: () => boolean = () => false;
  onMove: (x: number, y: number) => void = () => {};
  onRelease: () => void = () => {};
  onCancel: () => void = () => {};
  @State private pressed: boolean = false;
  private pointerId: number = -1;
  private timer: number = -1;
  private held: boolean = false;

  aboutToDisappear(): void { this.reset(true); }
  private availabilityChanged(): void { if (this.disabled) { this.reset(true); } }
  private phaseChanged(): void { if (this.phase === 'idle' || this.phase === 'error') { this.reset(false); } }

  private reset(cancel: boolean): void {
    clearTimeout(this.timer); this.timer = -1;
    const held = this.held;
    this.pointerId = -1; this.held = false; this.pressed = false;
    if (cancel && held) { this.onCancel(); }
  }

  private touch(event: TouchEvent): void {
    event.stopPropagation();
    if (event.type === TouchType.Cancel || event.touches.length > 1) { this.reset(true); return; }
    if (event.type === TouchType.Down) {
      if (this.disabled || this.phase === 'finishing' || this.pointerId !== -1) { return; }
      const point = event.changedTouches[0];
      this.pointerId = point.id; this.pressed = true;
      // Keep raw touch ownership after the finger leaves the composer; a long-press recognizer can cancel on movement.
      this.timer = setTimeout(() => {
        this.timer = -1;
        this.held = this.onHold();
        if (!this.held) { this.reset(false); }
      }, 220);
      return;
    }
    const point = event.changedTouches.find((touch: TouchObject) => touch.id === this.pointerId);
    if (!point) { return; }
    if (this.held) { this.onMove(point.windowX, point.windowY); }
    if (event.type === TouchType.Up) {
      const held = this.held; this.reset(false);
      if (held) { this.onRelease(); }
    }
  }

  private label(): string {
    if (this.phase === 'finishing') { return t('正在整理识别文字…'); }
    if (!this.held) { return t('按住说话'); }
    if (this.action === 'cancel') { return t('松开取消'); }
    if (this.action === 'edit') { return t('松开转为文字'); }
    return this.phase === 'preparing' ? t('准备中，请继续按住') : t('松开发送');
  }

  build() {
    Row() {
      Text(this.label()).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.action === 'cancel' && this.pressed ? $r('app.color.danger') : $r('app.color.text_primary'))
        .textAlign(TextAlign.Center).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
    }.id('hold-to-talk').width('100%').height(44).padding({ left: 8, right: 8 }).borderRadius(20)
      .backgroundColor(this.pressed ? this.action === 'cancel' ? $r('app.color.danger_container') :
        this.appearance.accentContainer : Color.Transparent)
      .opacity(this.disabled ? 0.4 : 1)
      .animation({ duration: Motion.fast, curve: Motion.standard })
      .accessibilityRole(AccessibilityRoleType.BUTTON).accessibilityText(this.label())
      .accessibilityDescription(t('按住说话，松开发送；滑到取消或编辑后松手。'))
      .onTouch((event: TouchEvent) => this.touch(event))
  }
}
