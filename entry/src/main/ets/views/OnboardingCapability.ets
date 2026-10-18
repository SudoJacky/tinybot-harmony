import { AppearanceStyle } from '../common/AppearanceStyle';
import { Motion, Radius } from '../common/Theme';
import { t } from '../model/I18n';

// One page of the capabilities theatre. The parent owns the Swiper, current index,
// footer and dots; this component owns only the content for this index.
@Component
export struct OnboardingCapability {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.appearance.dark') private dark: boolean = false;
  @Prop index: number = 0;
  @Prop @Watch('syncActive') active: boolean = true;
  @Prop @Watch('demoChanged') demoTick: number = 0;
  onActorArea: (area: Area) => void = () => {};
  onActorTap: () => void = () => {};
  onActorScroll: (id: string) => void = () => {};
  @State private revealed: boolean = false;
  private actorArea?: Area;

  private syncActive(): void {
    if (!this.active) { this.revealed = false; }
    else if (this.actorArea) { this.onActorArea(this.actorArea); }
  }

  private demoChanged(): void {
    if (this.active) { this.toggleResult(); }
  }

  private actorChanged(area: Area): void {
    this.actorArea = area;
    if (this.active) { this.onActorArea(area); }
  }

  private page(): number {
    return this.index === 1 || this.index === 2 ? this.index : 0;
  }

  private bubbleIcon(): Resource {
    if (this.page() === 1) { return $r('sys.symbol.doc_text'); }
    if (this.page() === 2) { return $r('sys.symbol.wand_and_stars'); }
    return $r('sys.symbol.ellipsis_message');
  }

  private leftIcon(): Resource {
    if (this.page() === 1) { return $r('sys.symbol.folder'); }
    if (this.page() === 2) { return $r('sys.symbol.list_bullet'); }
    return $r('sys.symbol.lightbulb');
  }

  private rightIcon(): Resource {
    if (this.page() === 1) { return $r('sys.symbol.square_and_pencil'); }
    if (this.page() === 2) { return $r('sys.symbol.checkmark_circle_fill'); }
    return $r('sys.symbol.questionmark_circle');
  }

  private resultIcon(): Resource {
    if (this.page() === 1) { return $r('sys.symbol.square_and_pencil'); }
    if (this.page() === 2) { return $r('sys.symbol.wand_and_stars'); }
    return $r('sys.symbol.lightbulb');
  }

  private bubbleText(): string {
    if (this.page() === 1) { return t('这份资料和草图，能一起看吗？'); }
    if (this.page() === 2) { return t('按这个 Skill 的步骤来做。'); }
    return t('帮我把这个想法理清楚。');
  }

  private title(): string {
    if (this.page() === 1) { return t('资料和草图，一起看'); }
    if (this.page() === 2) { return t('把方法变成步骤'); }
    return t('从一句话开始');
  }

  private description(): string {
    if (this.page() === 1) {
      return t('把文件和草图放进来，我会帮你梳理重点。');
    }
    if (this.page() === 2) {
      return t('选一个 Skill，我会把方法拆成步骤，陪你一步步完成。');
    }
    return t('想法还没成形也没关系，我会追问关键处，帮你理清下一步。');
  }

  private resultTitle(): string {
    if (this.page() === 1) { return t('先提炼，再整理'); }
    if (this.page() === 2) { return t('按步骤走一遍'); }
    return t('先问三个问题');
  }

  private resultBody(): string {
    if (this.page() === 1) { return t('从资料里提炼三条要点，再把草图的布局整理成可点的原型。'); }
    if (this.page() === 2) { return t('确认目标 → 收集资料 → 写出草稿 → 一起修改'); }
    return t('目标是什么？谁会用到它？一周后希望看到什么变化？');
  }

  private resultTransition(): TransitionEffect {
    if (this.appearance.effectStrength === 0) { return TransitionEffect.IDENTITY; }
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 }))
        .animation({ duration: Motion.medium, curve: Motion.enter }),
      TransitionEffect.OPACITY.animation({ duration: Motion.fast, curve: Motion.standard }));
  }

  private toggleResult(): void {
    if (!this.active) { return; }
    const duration = this.appearance.effectStrength > 0 ? Motion.medium : 0;
    this.getUIContext().animateTo({ duration: duration, curve: Motion.enter }, () => {
      if (!this.active) { return; }
      this.revealed = !this.revealed;
    });
  }

  @Builder
  stageChip(icon: Resource, angle: number) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(icon).fontSize(18).fontColor([this.appearance.accent])
    }.width(38).height(38).borderRadius(13).backgroundColor($r('app.color.surface_variant'))
      .border({ width: 1, color: $r('app.color.divider') })
      .rotate({ angle: angle }).accessibilityLevel('no')
  }

  @Builder
  question() {
    Row({ space: 8 }) {
      SymbolGlyph(this.bubbleIcon()).fontSize(16).fontColor([this.appearance.accent])
      Text(this.bubbleText()).fontFamily(this.appearance.fontFamily).fontSize(14).lineHeight(20)
        .fontColor($r('app.color.text_primary')).layoutWeight(1)
    }.width('100%').padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .backgroundColor($r('app.color.surface_variant')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.divider') })
  }

  @Builder
  resultCard() {
    Column({ space: 6 }) {
      Row({ space: 5 }) {
        SymbolGlyph(this.resultIcon()).fontSize(12).fontColor([this.appearance.onAccent])
        Text(t('示例')).fontFamily(this.appearance.fontFamily).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(this.appearance.onAccent).letterSpacing(0.4)
      }.padding({ left: 8, right: 9, top: 3, bottom: 3 })
        .backgroundColor(this.appearance.accent).borderRadius(Radius.sm)
      Text(this.resultTitle()).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.appearance.onAccentContainer).width('100%')
      Text(this.resultBody()).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(19)
        .fontColor(this.appearance.onAccentContainer).width('100%')
    }.id('onboarding-capability-result-' + this.index).width('100%').alignItems(HorizontalAlign.Start).padding(14)
      .margin({ top: 8 }).borderRadius(Radius.md).backgroundColor(this.appearance.accentContainer)
      .border({ width: 1, color: this.appearance.accentOutline })
      .shadow({ radius: 12, color: this.appearance.accentGlow, offsetY: 4 })
      .transition(this.resultTransition())
      .accessibilityGroup(true)
      .accessibilityText(t('本地示例结果') + '。' + this.resultTitle() + '。' + this.resultBody())
  }

  @Builder
  theatre() {
    Column({ space: 0 }) {
      this.question()
      Row() {
        this.stageChip(this.leftIcon(), -5)
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Column().width('100%').height('100%')
        }.id('onboarding-theatre-mascot-' + this.index).width(180).height(180)
          .backgroundColor(Color.Transparent).padding(0).enabled(this.active)
          .accessibilityText(this.revealed ? t('再轻点 Tiny，收起示例') : t('轻点 Tiny，看看示例'))
          .onClick(() => this.onActorTap())
          .onAreaChange((_old: Area, area: Area) => this.actorChanged(area))
        this.stageChip(this.rightIcon(), 5)
      }.width('100%').height(180).justifyContent(FlexAlign.SpaceBetween).alignItems(VerticalAlign.Center)
      if (this.revealed) {
        this.resultCard()
      }
      Text(this.revealed ? t('再轻点 Tiny，收起示例') : t('轻点 Tiny，看看示例'))
        .fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(17)
        .fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center).width('100%')
        .margin({ top: this.revealed ? 8 : 2 })
    }.width('100%').padding({ left: 12, right: 12, top: 12, bottom: 10 })
      .backgroundColor($r('app.color.surface')).borderRadius(28)
      .border({ width: 1, color: $r('app.color.divider') })
      .shadow({ radius: 20, color: this.dark ? '#40000000' : '#16000000', offsetY: 5 })
  }

  build() {
    Scroll() {
      Column({ space: 0 }) {
        this.theatre()
        Text(this.title()).id('onboarding-capability-title-' + this.page())
          .fontFamily(this.appearance.fontFamily).fontSize(24).fontWeight(FontWeight.Bold)
          .lineHeight(31).fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
          .width('100%').padding({ left: 8, right: 8 }).margin({ top: 18 })
        Text(this.description()).id('onboarding-capability-description-' + this.page())
          .fontFamily(this.appearance.fontFamily).fontSize(15).lineHeight(22)
          .fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          .width('100%').padding({ left: 8, right: 8 }).margin({ top: 7 })
      }.width('100%').alignItems(HorizontalAlign.Center).padding({ left: 4, right: 4, top: 2, bottom: 16 })
    }.id('onboarding-capability-' + this.index).width('100%').height('100%')
      .align(Alignment.Top)
      .backgroundColor($r('app.color.page_background'))
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .onDidScroll(() => {
        if (this.active) { this.onActorScroll('onboarding-theatre-mascot-' + this.index); }
      })
  }
}
