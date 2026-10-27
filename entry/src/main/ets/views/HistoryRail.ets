import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { Motion } from '../common/Theme';

// Desktop-parity history rail: the collapsed sidebar keeps one 36 vp control per
// action, stacked with the desktop's 12 vp rhythm. Expanding from here restores
// the full column when it fits; otherwise it reveals the same overlay drawer the
// phone layout uses, so history is never unreachable.
@Component
struct RailButton {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop icon: Resource = $r('sys.symbol.plus');
  @Prop label: string = '';
  @Prop active: boolean = false;
  @Prop disabled: boolean = false;
  compId: string = '';
  onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      SymbolGlyph(this.icon).fontSize(20)
        .fontColor([this.active ? this.appearance.accent : $r('app.color.text_secondary')])
    }
    .id(this.compId).width(36).height(36).borderRadius(12).padding(0)
    .backgroundColor(this.active ? this.appearance.accentContainer : Color.Transparent)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.surface_variant')) },
      normal: { .backgroundColor(this.active ? this.appearance.accentContainer : Color.Transparent) }
    })
    .clickEffect(Motion.pressSmall).enabled(!this.disabled)
    .accessibilityText(this.label).onClick(() => this.onTap())
  }
}

@Component
export struct HistoryRail {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop active: boolean = true;
  @Prop filesActive: boolean = false;
  onExpand: () => void = () => {};
  onNewChat: () => void = () => {};
  onSearch: () => void = () => {};
  onFiles: () => void = () => {};
  onTools: () => void = () => {};
  onSettings: () => void = () => {};

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Column() {
        Column({ space: 12 }) {
          RailButton({ icon: $r('sys.symbol.line_3_horizontal'), label: t('展开会话列表'),
            compId: 'workbench-rail-expand', disabled: !this.active, onTap: this.onExpand })
          RailButton({ icon: $r('sys.symbol.square_and_pencil'), label: t('新建对话'),
            compId: 'workbench-rail-new-chat', disabled: !this.active, onTap: this.onNewChat })
          RailButton({ icon: $r('sys.symbol.magnifyingglass'), label: t('搜索对话'),
            compId: 'workbench-rail-search', disabled: !this.active, onTap: this.onSearch })
        }.width('100%').alignItems(HorizontalAlign.Center)
        Blank().layoutWeight(1)
        Column({ space: 12 }) {
          RailButton({ icon: $r('sys.symbol.folder'), label: t('工作区文件'), compId: 'workbench-rail-files',
            active: this.filesActive, disabled: !this.active, onTap: this.onFiles })
          RailButton({ icon: $r('sys.symbol.wrench_and_screwdriver'), label: t('记忆与工具'),
            compId: 'workbench-rail-tools', disabled: !this.active, onTap: this.onTools })
          RailButton({ icon: $r('sys.symbol.gearshape'), label: t('设置'), compId: 'workbench-rail-settings',
            disabled: !this.active, onTap: this.onSettings })
        }.width('100%').alignItems(HorizontalAlign.Center)
      }.width('100%').height('100%').padding({ left: 10, right: 10, top: 12, bottom: 12 })
    }.width('100%').height('100%')
    .border({ width: { right: 0.5 }, color: $r('app.color.divider') })
  }
}
