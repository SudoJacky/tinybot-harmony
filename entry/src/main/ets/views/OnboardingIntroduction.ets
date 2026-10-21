import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion } from '../common/Theme';
import { onboardingIntroduction } from '../model/Onboarding';
import { OnboardingExampleDeck } from './OnboardingExampleDeck';

// A local introduction: speech takes turns above the shared actor, with finished examples below.
@Component
export struct OnboardingIntroduction {
  @StorageProp('tinybot.appearance.style') @Watch('syncPlayback') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncPlayback') private foreground: boolean = true;
  @Prop @Watch('syncPlayback') active: boolean = true;
  @Prop bodyHeight: number = 560;
  onActorArea: (area: Area) => void = () => {};
  onLook: (down: boolean, x: number) => void = () => {};
  onSpeak: (line: number) => void = () => {};
  @State private line: number = 0;
  @State private speechHeight: number = 88;
  private mounted: boolean = false;
  @State private visible: boolean = false;
  private timer: number = -1;
  private revision: number = 0;
  private spokenLine: number = -1;

  aboutToAppear(): void { this.mounted = true; }

  aboutToDisappear(): void {
    this.mounted = false;
    this.stopPlayback();
  }

  private stopPlayback(): void {
    this.revision++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private visibilityChanged(ratio: number): void {
    this.visible = ratio > 0;
    this.syncPlayback();
  }

  private syncPlayback(): void {
    this.stopPlayback();
    if (!this.mounted || !this.visible || !this.active || !this.foreground || this.appearance.effectStrength === 0) { return; }
    if (this.spokenLine !== this.line) { this.spokenLine = this.line; this.onSpeak(this.line); }
    if (this.line >= onboardingIntroduction().length - 1) { return; }
    const revision = this.revision;
    this.timer = setTimeout(() => {
      if (revision !== this.revision || !this.mounted || !this.visible || !this.active || !this.foreground) { return; }
      this.timer = -1;
      this.getUIContext().animateTo({ duration: 280, curve: Motion.enter }, () => {
        this.line++;
      });
      this.syncPlayback();
    }, 3200);
  }

  private contentTransition(): TransitionEffect {
    if (this.appearance.effectStrength === 0) { return TransitionEffect.IDENTITY; }
    return TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 6 }))
      .animation({ duration: 280, curve: Motion.enter });
  }

  private actorDiameter(): number { return Math.max(40, Math.min(136, this.bodyHeight - this.speechHeight - 332)); }

  @Builder
  speech() {
    Column() {
      if (this.appearance.effectStrength === 0) {
        Text(onboardingIntroduction().join('\n')).fontFamily(this.appearance.fontFamily)
          .fontSize(16).lineHeight(25).fontColor($r('app.color.text_primary')).width('100%')
      } else {
        ForEach([this.line], (line: number) => {
          Text(onboardingIntroduction()[line]).fontFamily(this.appearance.fontFamily)
            .fontSize(16).lineHeight(25).fontColor($r('app.color.text_primary')).width('100%')
            .transition(this.contentTransition())
        }, (line: number) => line.toString())
      }
    }.id('onboarding-introduction-speech').width('100%').constraintSize({ minHeight: 88 })
      .justifyContent(FlexAlign.Center).padding(18).backgroundColor($r('app.color.surface')).borderRadius(20)
      .onAreaChange((_old: Area, area: Area) => { this.speechHeight = Number(area.height); })
  }

  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        this.speech()
        Rect().width(14).height(14).radius(2).fill($r('app.color.surface'))
          .rotate({ angle: 45 }).translate({ y: 5 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }.width('100%')
      Stack({ alignContent: Alignment.Center }) {
        Column().width(this.actorDiameter()).height(this.actorDiameter()).id('onboarding-actor-slot-2')
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          .onAreaChange((_old: Area, area: Area) => this.onActorArea(area))
      }.width('100%').height(this.actorDiameter() + 8)
      OnboardingExampleDeck({ active: this.active && this.foreground && this.visible,
        speechLine: this.line, compact: this.bodyHeight < 520, onLook: this.onLook })
    }.width('100%').constraintSize({ minHeight: this.bodyHeight }).justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .onVisibleAreaChange([0, 1], (_expanding: boolean, ratio: number) => this.visibilityChanged(ratio))
  }
}
