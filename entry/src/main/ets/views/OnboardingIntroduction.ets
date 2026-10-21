import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion } from '../common/Theme';
import { OnboardingExample, OnboardingExampleColumn, onboardingExamples, onboardingIntroduction } from '../model/Onboarding';
import { t } from '../model/I18n';

// A local introduction: speech takes turns above the shared actor, with finished examples below.
@Component
export struct OnboardingIntroduction {
  @StorageProp('tinybot.appearance.style') @Watch('syncPlayback') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncPlayback') private foreground: boolean = true;
  @Prop @Watch('syncPlayback') active: boolean = true;
  @Prop bodyHeight: number = 560;
  onActorArea: (area: Area) => void = () => {};
  @State private line: number = 0;
  private mounted: boolean = false;
  private visible: boolean = false;
  private timer: number = -1;
  private revision: number = 0;

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
    if (!this.mounted || !this.visible || !this.active || !this.foreground ||
      this.appearance.effectStrength === 0 || this.line >= onboardingIntroduction().length - 1) { return; }
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

  private actorDiameter(): number { return Math.max(120, Math.min(176, this.bodyHeight - 432)); }

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
  }

  @Builder
  exampleCard(item: OnboardingExample, index: number) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text(item.documentTitle).fontFamily(this.appearance.fontFamily).fontSize(14).lineHeight(20)
          .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text(t('示例')).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(18)
          .fontColor(this.appearance.accent)
      }.width('100%')
      Row({ space: 8 }) {
        ForEach(item.columns, (column: OnboardingExampleColumn) => {
          Column({ space: 3 }) {
            Text(column.label).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(17)
              .fontColor($r('app.color.text_secondary')).width('100%')
            Text(column.value).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(19)
              .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }, (column: OnboardingExampleColumn) => column.label)
      }.width('100%').alignItems(VerticalAlign.Top)
    }.id('onboarding-introduction-example-' + index).width('100%')
      .padding(12).backgroundColor($r('app.color.surface')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.divider') })
      .transition(this.appearance.effectStrength > 0 ? Motion.rise(index, 6) : TransitionEffect.IDENTITY)
      .accessibilityGroup(true)
  }

  build() {
    Column({ space: 12 }) {
      this.speech()
      Stack({ alignContent: Alignment.Center }) {
        Column().width(this.actorDiameter()).height(this.actorDiameter()).id('onboarding-actor-slot-2')
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          .onAreaChange((_old: Area, area: Area) => this.onActorArea(area))
      }.width('100%').height(this.actorDiameter() + 12)
      Column({ space: 8 }) {
        ForEach(onboardingExamples(), (item: OnboardingExample, index: number) => {
          this.exampleCard(item, index)
        }, (item: OnboardingExample) => item.title)
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: this.bodyHeight }).justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })
      .onVisibleAreaChange([0, 1], (_expanding: boolean, ratio: number) => this.visibilityChanged(ratio))
  }
}
