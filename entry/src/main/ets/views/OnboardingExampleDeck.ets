import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion } from '../common/Theme';
import { OnboardingExample, onboardingExamples } from '../model/Onboarding';
import { t } from '../model/I18n';
import { OnboardingExamplePage } from './OnboardingExamplePage';

// One finite tour during the second speech line. Touch always takes ownership.
@Component
export struct OnboardingExampleDeck {
  @StorageProp('tinybot.appearance.style') @Watch('syncPlayback') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('syncPlayback') active: boolean = false;
  @Prop @Watch('syncPlayback') speechLine: number = 0;
  @Prop compact: boolean = false;
  onLook: (down: boolean, x: number) => void = () => {};
  @State private selected: number = 0;
  @State private stageWidth: number = 328;
  private mounted: boolean = false;
  private manual: boolean = false;
  private tourStep: number = -1;
  private timer: number = -1;
  private lookTimer: number = -1;
  private revision: number = 0;

  aboutToAppear(): void { this.mounted = true; this.syncPlayback(); }
  aboutToDisappear(): void { this.mounted = false; this.stopPlayback(); }

  private stopPlayback(): void {
    this.revision++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    if (this.lookTimer >= 0) { clearTimeout(this.lookTimer); this.lookTimer = -1; }
    this.onLook(false, 0);
  }

  private syncPlayback(): void {
    this.stopPlayback();
    if (!this.mounted || !this.active || this.appearance.effectStrength === 0 || this.manual) { return; }
    if (this.speechLine > 1) {
      if (this.tourStep >= 0 && this.tourStep < 3) { this.tourStep = 3; this.select(0); }
      return;
    }
    if (this.speechLine !== 1 || this.tourStep >= 3) { return; }
    if (this.tourStep < 0) { this.tourStep = 0; this.select(0); }
    else { this.onLook(true, (this.selected - 1) * 5); }
    this.scheduleTour();
  }

  private scheduleTour(): void {
    const revision = this.revision;
    this.timer = setTimeout(() => {
      if (revision !== this.revision || !this.mounted || !this.active || this.manual) { return; }
      this.timer = -1;
      this.tourStep++;
      this.select(this.tourStep % 3);
      if (this.tourStep < 3) { this.scheduleTour(); }
    }, 1000);
  }

  private select(index: number): void {
    const change = (): void => { this.selected = (index + 3) % 3; };
    if (this.appearance.effectStrength === 0) { change(); return; }
    this.getUIContext().animateTo({ duration: 280, curve: Motion.enter }, change);
    if (this.lookTimer >= 0) { clearTimeout(this.lookTimer); }
    if (!this.manual) {
      this.onLook(this.tourStep < 3, this.tourStep < 3 ? (this.selected - 1) * 5 : 0);
      return;
    }
    this.onLook(true, (this.selected - 1) * 5);
    const revision = this.revision;
    this.lookTimer = setTimeout(() => {
      if (revision !== this.revision || !this.mounted) { return; }
      this.lookTimer = -1;
      this.onLook(false, 0);
    }, 600);
  }

  private choose(index: number): void {
    if (!this.mounted || !this.active) { return; }
    this.manual = true;
    this.stopPlayback();
    this.select(index);
  }

  private side(index: number): number {
    if (index === this.selected) { return 0; }
    return index === (this.selected + 1) % 3 ? 1 : -1;
  }

  private fan(): boolean { return !this.compact && this.appearance.effectStrength > 0; }
  private sideOffset(): number { return Math.max(0, Math.min(92, (this.stageWidth - 170) / 2)); }

  build() {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.Center }) {
        ForEach(onboardingExamples(), (item: OnboardingExample, index: number) => {
          OnboardingExamplePage({ item: item, selected: index === this.selected, playing: this.active })
            .id('onboarding-example-' + item.kind)
            .width(176).height(228)
            .scale({ x: this.side(index) === 0 || !this.fan() ? 1 : 0.86,
              y: this.side(index) === 0 || !this.fan() ? 1 : 0.86 })
            .rotate({ angle: this.fan() ? this.side(index) * 5 : 0 })
            .translate({ x: this.fan() ? this.side(index) * this.sideOffset() : 0,
              y: this.fan() && this.side(index) !== 0 ? 8 : 0 })
            .opacity(this.side(index) === 0 ? 1 : this.fan() ? 0.9 : 0)
            .zIndex(index === this.selected ? 2 : 0)
            .visibility(this.side(index) === 0 || this.fan() ? Visibility.Visible : Visibility.Hidden)
            .accessibilityGroup(true).accessibilityText(item.description)
            .accessibilityDescription(index === this.selected ? t('已选择') : t('轻点查看这页作品'))
            .onClick(() => this.choose(index))
        }, (item: OnboardingExample) => item.kind)
      }.id('onboarding-example-stage').width('100%').height(248)
        .onAreaChange((_old: Area, area: Area) => { this.stageWidth = Number(area.width); })
        .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
          .onActionEnd((event: GestureEvent) => {
            if (Math.abs(event.offsetX) >= 24) { this.choose(this.selected + (event.offsetX < 0 ? 1 : -1)); }
          }))
      Row({ space: 8 }) {
        Row({ space: 0 }) {
          ForEach(onboardingExamples(), (item: OnboardingExample, index: number) => {
            Button({ type: ButtonType.Normal }) {
              Circle().width(index === this.selected ? 6 : 5).height(index === this.selected ? 6 : 5)
                .fill(index === this.selected ? this.appearance.accent : $r('app.color.text_tertiary'))
                .opacity(index === this.selected ? 1 : 0.45)
            }.id('onboarding-example-dot-' + index).width(28).height(44)
              .backgroundColor(Color.Transparent).borderRadius(14)
              .accessibilityText(t('查看示例：{0}', [item.title]))
              .accessibilityDescription(index === this.selected ? t('已选择') : '')
              .onClick(() => this.choose(index))
          }, (item: OnboardingExample) => item.kind)
        }
        Text(t('{0} · 示例', [onboardingExamples()[this.selected].title]))
          .id('onboarding-example-caption').fontFamily(this.appearance.fontFamily).fontSize(12)
          .fontColor($r('app.color.text_secondary')).maxLines(1)
      }.width('100%').justifyContent(FlexAlign.Center)
    }.width('100%')
  }
}
