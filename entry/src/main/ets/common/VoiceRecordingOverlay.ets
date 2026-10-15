import { AppearanceStyle } from './AppearanceStyle';
import { Motion, Space } from './Theme';
import { SpeechOrb } from './SpeechOrb';
import { t } from '../model/I18n';
import { VoiceAction, VoiceTargetRect } from '../model/VoiceGesture';
import { SpeechPhase } from '../services/SpeechInput';

@Component
export struct VoiceRecordingOverlay {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop phase: SpeechPhase = 'idle';
  @Prop text: string = '';
  @Prop speaking: boolean = false;
  @Prop action: VoiceAction = 'send';
  onTargetArea: (action: VoiceAction, rect: VoiceTargetRect) => void = () => {};
  onCancel: () => void = () => {};
  onEdit: () => void = () => {};

  private targetArea(action: VoiceAction, area: Area): void {
    this.onTargetArea(action, { x: Number(area.globalPosition.x), y: Number(area.globalPosition.y),
      width: Number(area.width), height: Number(area.height) });
  }

  @Builder
  target(kind: VoiceAction, icon: Resource, label: string) {
    Column({ space: 4 }) {
      Button({ type: ButtonType.Capsule, stateEffect: false }) {
        SymbolGlyph(icon).fontSize(22).fontColor([this.action === kind ?
          kind === 'cancel' ? $r('app.color.on_danger') : this.appearance.onAccent : $r('app.color.text_primary')])
      }.id(kind === 'cancel' ? 'cancel-voice-message' : 'edit-voice-message').width(64).height(48).padding(0).borderRadius(24)
        .backgroundColor(this.action === kind ? kind === 'cancel' ? $r('app.color.danger') : this.appearance.accent : $r('app.color.surface'))
        .scale({ x: this.action === kind ? 1.1 : 1, y: this.action === kind ? 1.1 : 1 })
        .shadow({ radius: 12, color: '#16000000', offsetY: 3 })
        .animation({ duration: Motion.fast, curve: Motion.standard })
        .accessibilityText(label).onClick(() => { if (kind === 'cancel') { this.onCancel(); } else { this.onEdit(); } })
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(12)
        .fontColor(this.action === kind && kind === 'cancel' ? $r('app.color.danger') : $r('app.color.text_secondary'))
    }.width(80).onAreaChange((_previous: Area, current: Area) => this.targetArea(kind, current))
  }

  build() {
    Column({ space: Space.sm }) {
      if (this.text.trim().length > 0) {
        Scroll() {
          Text(this.text).id('voice-transcript').fontFamily(this.appearance.fontFamily).fontSize(17).lineHeight(25)
            .fontColor($r('app.color.text_primary')).width('100%').padding(16)
        }.id('voice-transcript-panel').width('100%').constraintSize({ maxHeight: 120 }).scrollBar(BarState.Auto)
          .backgroundColor($r('app.color.surface')).borderRadius(22)
          .shadow({ radius: 18, color: '#12000000', offsetY: 4 })
          .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fast, curve: Motion.standard }))
      }
      Column({ space: Space.sm }) {
        SpeechOrb({ phase: this.phase, speaking: this.speaking })
        Row() {
          this.target('cancel', $r('sys.symbol.xmark'), t('取消'))
          Blank()
          this.target('edit', $r('sys.symbol.square_and_pencil'), t('编辑'))
        }.width('100%')
      }.width('100%')
    }.id('voice-recording-overlay').width('100%').padding({ left: Space.lg, right: Space.lg, bottom: Space.md })
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
