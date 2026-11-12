import { AnimatorResult } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { SegmentFrame, SegmentedMotion } from '../common/SegmentedMotion';
import { Btn, Space } from '../common/Theme';
import { t } from '../model/I18n';

interface SettingsCategory { key: string; title: string; icon: Resource; }
const CATEGORY_TRACK_RADIUS: number = 25;
const CATEGORIES: SettingsCategory[] = [
  { key: 'account', title: '账号', icon: $r('sys.symbol.person') },
  { key: 'models', title: '模型与服务', icon: $r('sys.symbol.cloud') },
  { key: 'assistant', title: '助手偏好', icon: $r('sys.symbol.square_and_pencil') },
  { key: 'tools', title: '工具与权限', icon: $r('sys.symbol.wrench_and_screwdriver') },
  { key: 'appearance', title: '界面与语言', icon: $r('sys.symbol.picture') },
  { key: 'data', title: '数据与用量', icon: $r('sys.symbol.rectangle_stack') },
  { key: 'help', title: '帮助与关于', icon: $r('sys.symbol.questionmark_circle') }
];

export function settingsCategoryTitle(key: string): string {
  return t(CATEGORIES.find((item: SettingsCategory) => item.key === key)?.title || '设置');
}

@Component
export struct SettingsCategoryBar {
  @StorageProp('tinybot.appearance.style') @Watch('motionChanged') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('selectionChanged') selected: string = 'models';
  @State private thumb: SegmentFrame = { left: 0, right: 0 };
  onSelect: (key: string) => void = () => {};
  private scroller: Scroller = new Scroller();
  private segments: Map<string, SegmentFrame> = new Map();
  private viewportWidth: number = 0;
  private animator?: AnimatorResult;

  aboutToDisappear(): void { this.stopMotion(); }

  private stopMotion(): void {
    const animator = this.animator;
    this.animator = undefined;
    animator?.cancel();
  }

  private moveThumb(target: SegmentFrame, animated: boolean): void {
    const from = this.thumb;
    this.stopMotion();
    if (!animated || from.right <= from.left || this.appearance.effectStrength === 0 ||
      (from.left === target.left && from.right === target.right)) {
      this.thumb = target;
      return;
    }
    const animator = this.getUIContext().createAnimator({
      duration: SegmentedMotion.duration, easing: 'linear', delay: 0, fill: 'forwards',
      direction: 'normal', iterations: 1, begin: 0, end: 1
    });
    animator.onFrame = (progress: number): void => {
      if (this.animator === animator) { this.thumb = SegmentedMotion.sample(from, target, progress); }
    };
    animator.onFinish = (): void => {
      if (this.animator === animator) { this.thumb = target; this.animator = undefined; }
    };
    this.animator = animator;
    animator.play();
  }

  private reveal(target: SegmentFrame, animated: boolean): void {
    if (this.viewportWidth <= 0) { return; }
    const offset = this.scroller.currentOffset().xOffset;
    const next = target.left < offset ? Math.max(0, target.left - 3) :
      target.right > offset + this.viewportWidth ? target.right + 3 - this.viewportWidth : offset;
    if (next !== offset) {
      this.scroller.scrollTo({ xOffset: next, yOffset: 0,
        animation: animated && this.appearance.effectStrength > 0 ?
          { duration: SegmentedMotion.duration, curve: Curve.EaseOut } : false });
    }
  }

  private selectionChanged(): void {
    const target = this.segments.get(this.selected);
    if (!target) { return; }
    this.moveThumb(target, true);
    this.reveal(target, true);
  }

  private motionChanged(): void {
    const target = this.segments.get(this.selected);
    if (target && this.appearance.effectStrength === 0) {
      this.moveThumb(target, false);
      this.reveal(target, false);
    }
  }

  private segmentChanged(key: string, area: Area): void {
    const left = Number(area.position.x);
    const right = left + Number(area.width);
    const previous = this.segments.get(key);
    if (right <= left || (previous?.left === left && previous?.right === right)) { return; }
    const target: SegmentFrame = { left: left, right: right };
    this.segments.set(key, target);
    if (key === this.selected) {
      const animated = !!this.animator;
      this.moveThumb(target, animated);
      this.reveal(target, animated);
    }
  }

  private viewportChanged(area: Area): void {
    this.viewportWidth = Number(area.width);
    const target = this.segments.get(this.selected);
    if (target) { this.reveal(target, false); }
  }

  build() {
    Column() {
      Column() {
        Scroll(this.scroller) {
          Stack({ alignContent: Alignment.TopStart }) {
            if (this.thumb.right > this.thumb.left) {
              Column().id('settings-category-selection').width(this.thumb.right - this.thumb.left).height(44)
                .borderRadius(22).backgroundColor($r('app.color.surface'))
                .position({ x: 0, y: 3 }).translate({ x: this.thumb.left })
                .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
            }
            Row({ space: 2 }) {
              ForEach(CATEGORIES, (item: SettingsCategory) => {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: Space.sm }) {
                    SymbolGlyph(item.icon).fontSize(18)
                      .fontColor([this.selected === item.key ? $r('app.color.text_primary') : $r('app.color.text_secondary')])
                      .accessibilityLevel('no')
                    Text(t(item.title)).fontSize(14).fontFamily(this.appearance.fontFamily).maxLines(1)
                      .fontWeight(this.selected === item.key ? FontWeight.Medium : FontWeight.Regular)
                      .fontColor(this.selected === item.key ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                  }
                }.height(44).padding({ left: Space.md, right: Space.md }).borderRadius(22)
                  .backgroundColor(Color.Transparent)
                  .accessibilityText(t(item.title)).accessibilitySelected(this.selected === item.key)
                  .id('settings-open-' + item.key).onClick(() => this.onSelect(item.key))
                  .onAreaChange((_previous: Area, current: Area) => this.segmentChanged(item.key, current))
              }, (item: SettingsCategory) => item.key)
            }.height(50).padding({ left: 3, right: 3 })
          }.height(50)
        }.scrollable(ScrollDirection.Horizontal).width('100%').height(50).scrollBar(BarState.Off)
          .backgroundColor($r('app.color.surface_variant')).borderRadius(CATEGORY_TRACK_RADIUS).clip(true)
          .id('settings-category-bar').onAreaChange((_previous: Area, current: Area) => this.viewportChanged(current))
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.xs, bottom: Space.sm })
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
    }.width('100%')
  }
}

@Component
export struct SettingsNavigation {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop selected: string = 'models';
  onSelect: (key: string) => void = () => {};
  onChat: () => void = () => {};
  build() {
    Column({ space: Space.md }) {
      Button(t('返回对话')).attributeModifier(Btn.text).id('settings-return-chat').onClick(this.onChat)
      Text(t('设置')).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        .width('100%').padding({ left: 12, top: 12, bottom: 12 })
      ForEach(CATEGORIES, (item: SettingsCategory) => {
        Button() {
          Row({ space: 12 }) {
            SymbolGlyph(item.icon).fontSize(20).fontColor([this.selected === item.key ? this.appearance.accent : $r('app.color.text_secondary')])
            Text(t(item.title)).fontSize(15).layoutWeight(1).textAlign(TextAlign.Start)
              .fontColor(this.selected === item.key ? this.appearance.onAccentContainer : $r('app.color.text_primary'))
          }.width('100%')
        }.fontFamily(this.appearance.fontFamily).id('settings-category-' + item.key)
          .width('100%').height(48).padding({ left: 12, right: 12 }).borderRadius(12)
          .backgroundColor(this.selected === item.key ? this.appearance.accentContainer : Color.Transparent)
          .accessibilitySelected(this.selected === item.key).onClick(() => this.onSelect(item.key))
      }, (item: SettingsCategory) => item.key)
      Blank()
    }.width('100%').height('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.page_background'))
  }
}
