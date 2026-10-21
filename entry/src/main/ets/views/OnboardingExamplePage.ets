import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion } from '../common/Theme';
import { OnboardingExample, OnboardingResearch, OnboardingTrip, OnboardingDigest } from '../model/Onboarding';

@Component
export struct OnboardingExamplePage {
  @StorageProp('tinybot.appearance.style') @Watch('syncReveal') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop item: OnboardingExample;
  @Prop @Watch('syncReveal') selected: boolean = false;
  @Prop @Watch('syncReveal') playing: boolean = false;
  @State private revealed: boolean = true;
  private mounted: boolean = false;
  private timer: number = -1;
  private revision: number = 0;

  aboutToAppear(): void { this.mounted = true; this.syncReveal(); }
  aboutToDisappear(): void { this.mounted = false; this.cancelReveal(); }

  private cancelReveal(): void {
    this.revision++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private syncReveal(): void {
    this.cancelReveal();
    this.revealed = !this.mounted || !this.selected || !this.playing || this.appearance.effectStrength === 0;
    if (this.revealed) { return; }
    const revision = this.revision;
    this.timer = setTimeout(() => {
      if (revision !== this.revision || !this.mounted) { return; }
      this.timer = -1;
      this.revealed = true;
    }, 32);
  }

  private motion(duration: number, delay: number = 0): AnimateParam {
    return { duration: this.revealed && this.selected && this.playing && this.appearance.effectStrength > 0 ? duration : 0,
      delay: this.revealed && this.selected && this.playing && this.appearance.effectStrength > 0 ? delay : 0,
      curve: Motion.enter };
  }

  // ArkUI Path coordinates are physical pixels; the paper layout is in vp.
  private path(commands: string): string {
    return commands.split(' ').map((part: string) => {
      const value = Number(part);
      return Number.isNaN(value) ? part : this.getUIContext().vp2px(value).toString();
    }).join(' ');
  }

  @Builder
  label(value: string, size: number = 10, strong: boolean = false) {
    Text(value).fontFamily(this.appearance.fontFamily).fontSize(size).lineHeight(size + 4)
      .fontWeight(strong ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(strong ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
      .maxLines(1)
  }

  @Builder
  flag() {
    Path().width(10).height(14).commands(this.path('M 1 13 L 1 1 L 9 1 L 7 4 L 9 7 L 1 7'))
      .fill($r('app.color.tiny_coral')).stroke($r('app.color.tiny_coral')).strokeWidth(1)
  }

  @Builder
  research(item: OnboardingResearch) {
    Column({ space: 4 }) {
      Text(item.heading).fontFamily(this.appearance.fontFamily).fontSize(10).lineHeight(14).fontColor(this.appearance.accent)
      this.label(item.subject, 15, true)
      Row({ space: 8 }) {
        ForEach(item.traffic, (height: number, index: number) => {
          Column({ space: 3 }) {
            Stack({ alignContent: Alignment.Bottom }) {
              Rect().width(15).height(height).radius(3)
                .fill(index === 2 ? this.appearance.accent : $r('app.color.surface_variant'))
                .scale({ x: 1, y: this.revealed ? 1 : 0, centerY: '100%' })
                .animation(this.motion(320, index * 40))
            }.height(34)
            this.label(item.hours[index])
          }
        }, (_height: number, index: number) => index.toString())
      }.width('100%').justifyContent(FlexAlign.SpaceBetween)
      this.label(item.peak, 13, true)
      Row({ space: 5 }) {
        ForEach(item.tags, (tag: string) => {
          Text(tag).fontFamily(this.appearance.fontFamily).fontSize(10).lineHeight(14)
            .fontColor($r('app.color.text_secondary')).padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.surface_variant')).borderRadius(5)
        }, (tag: string) => tag)
      }
      Stack({ alignContent: Alignment.TopEnd }) {
        Column({ space: 2 }) {
          this.label(item.suggestion)
          this.label(item.offer, 12, true)
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 8, right: 5, top: 3, bottom: 3 })
          .backgroundColor(this.appearance.accentTint).borderRadius(5)
        Circle().width(7).height(7).fill($r('app.color.tiny_coral')).translate({ x: -6, y: -3 })
      }.width('100%').rotate({ angle: -2 }).translate({ y: this.revealed ? 0 : -8 })
        .opacity(this.revealed ? 1 : 0).animation(this.motion(300, 360))
      this.label(item.source)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  mapPoint(index: number, x: number, y: number) {
    Stack() {
      Circle().width(16).height(16).fill($r('app.color.surface'))
        .stroke(this.appearance.accent).strokeWidth(1)
      Text((index + 1).toString()).fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.appearance.accent)
    }.width(16).height(16).position({ x: x, y: y })
      .scale({ x: this.revealed ? 1 : 0, y: this.revealed ? 1 : 0 })
      .animation(this.motion(280, index * 180))
  }

  @Builder
  routeMap() {
    Stack({ alignContent: Alignment.TopStart }) {
      Path().width(148).height(64).commands(this.path('M 13 12 C 38 -3 65 4 65 23 C 63 42 36 60 18 51 C 2 43 1 25 13 12 Z'))
        .fill(this.appearance.accentTint).stroke(Color.Transparent)
      Row() {
        Path().width(148).height(64).commands(this.path('M 27 21 L 79 15 L 116 48'))
          .fill(Color.Transparent).stroke(this.appearance.accent).strokeWidth(1.5)
          .strokeDashArray([3, 4]).strokeDashOffset(this.revealed ? 0 : 14)
          .animation(this.motion(550))
      }.width(this.revealed ? 148 : 0).height(64).clip(true).animation(this.motion(550))
      this.mapPoint(0, 19, 13)
      this.mapPoint(1, 71, 7)
      this.mapPoint(2, 108, 40)
      Column() { this.flag() }.position({ x: 131, y: 33 })
        .opacity(this.revealed ? 1 : 0).animation(this.motion(220, 400))
    }.width(148).height(64).backgroundColor($r('app.color.surface_variant')).borderRadius(9)
  }

  @Builder
  trip(item: OnboardingTrip) {
    Column({ space: 6 }) {
      Row() {
        this.label(item.heading, 15, true)
        Blank()
        this.label(item.weather)
      }.width('100%')
      this.label(item.duration, 10)
      this.routeMap()
      Stack({ alignContent: Alignment.TopStart }) {
        Rect().width(1).height(42).fill(this.appearance.accentOutline).position({ x: 8, y: 10 })
        Column({ space: 5 }) {
          ForEach(item.stops, (stop: string, index: number) => {
            Row({ space: 8 }) {
              Text('D' + (index + 1)).fontSize(10).lineHeight(16).fontWeight(FontWeight.Medium)
                .fontColor(this.appearance.accent).backgroundColor($r('app.color.surface')).width(18)
              this.label(stop, 11, true)
            }
          }, (stop: string) => stop)
        }
      }.width('100%')
      Path().width(148).height(1).commands(this.path('M 0 0 L 148 0')).stroke($r('app.color.divider'))
        .strokeWidth(1).strokeDashArray([2, 4])
      this.label(item.footer)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  sourceLines() {
    Column({ space: 5 }) {
      ForEach([0, 1, 2, 3], (index: number) => {
        Row({ space: 5 }) {
          Stack({ alignContent: Alignment.Start }) {
            Rect().width(index === 3 ? 83 : index === 0 ? 112 : 122).height(4).radius(2)
              .fill($r('app.color.surface_variant'))
            if (index === 1 || index === 3) {
              Rect().width(60).height(9).radius(2).fill(this.appearance.accentTint)
                .translate({ x: index === 1 ? 30 : 12 })
                .scale({ x: this.revealed ? 1 : 0, y: 1, centerX: 0 })
                .animation(this.motion(400, index === 1 ? 0 : 120))
            }
          }.width(122).height(7)
          if (index === 0 || index === 2) {
            Text(index === 0 ? '①' : '②').fontSize(10).fontColor(this.appearance.accent)
          }
        }.height(7)
      }, (index: number) => index.toString())
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 3, bottom: 3 })
  }

  @Builder
  digest(item: OnboardingDigest) {
    Column({ space: 7 }) {
      this.label(item.heading, 13, true)
      Text(item.compression).fontFamily(this.appearance.fontFamily).fontSize(11).lineHeight(16)
        .fontWeight(FontWeight.Medium).fontColor(this.appearance.accent)
        .padding({ left: 7, right: 7, top: 3, bottom: 3 }).backgroundColor(this.appearance.accentTint).borderRadius(5)
      this.sourceLines()
      Rect().width('100%').height(1).fill($r('app.color.divider'))
      Column({ space: 5 }) {
        ForEach(item.conclusions, (conclusion: string, index: number) => {
          Column({ space: 2 }) {
            Row({ space: 5 }) {
              Text(['①', '②', '③'][index]).fontSize(11).fontColor(this.appearance.accent)
              this.label(conclusion, 11, true)
            }
            if (index === 1) {
              Row({ space: 4 }) {
                this.flag()
                this.label(item.verification)
              }.padding({ left: 18 })
            }
          }.alignItems(HorizontalAlign.Start).opacity(this.revealed ? 1 : 0)
            .translate({ y: this.revealed ? 0 : 4 }).animation(this.motion(220, 540 + index * 80))
        }, (conclusion: string) => conclusion)
      }.alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        if (this.item.kind === 'research') { this.research(this.item as OnboardingResearch) }
        else if (this.item.kind === 'trip') { this.trip(this.item as OnboardingTrip) }
        else { this.digest(this.item as OnboardingDigest) }
      }.width('100%').height('100%').padding(14)
      if (this.item.kind === 'digest') {
        Path().width(18).height(18).commands(this.path('M 0 0 L 18 18 L 0 18 Z'))
          .fill($r('app.color.surface_variant')).stroke(Color.Transparent).translate({ x: -1, y: 1 })
      }
      if (this.item.kind === 'trip') {
        Circle().width(10).height(10).fill($r('app.color.page_background')).position({ x: -5, y: 191 })
        Circle().width(10).height(10).fill($r('app.color.page_background')).position({ x: 171, y: 191 })
      }
    }.width(176).height(228).backgroundColor($r('app.color.surface')).borderRadius(14)
      .border({ width: 0.5, color: $r('app.color.divider') })
      .shadow({ radius: 16, offsetY: 6, color: '#14000000' })
      .accessibilityLevel('no-hide-descendants')
  }
}
