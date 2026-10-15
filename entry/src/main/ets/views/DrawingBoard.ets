import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { HandwriteComponent, HandwriteController, HiddenToolType, PenType } from '@kit.Penkit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Radius, Space, systemInsets } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { DrawingDraft } from '../model/DrawingDraft';
import { t } from '../model/I18n';

@Component
export struct DrawingBoard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink draft: DrawingDraft;
  onClose: () => void = () => {};
  onAdd: (pixel: image.PixelMap) => Promise<void> = async () => {};
  @State private ready: boolean = false;
  @State private error: string = '';
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  private supported: boolean = canIUse('SystemCapability.Stylus.Handwrite');
  private controller: HandwriteController = new HandwriteController();
  private notePath: string = '';

  aboutToAppear(): void {
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetTop = insets[0]; this.insetBottom = insets[1]; });
    this.draft.hasContent = (): boolean => {
      if (!this.ready) { return false; }
      const range = this.controller.getContentRange();
      return range.right > range.left && range.bottom > range.top;
    };
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.notePath = context.cacheDir + '/drawing-' + util.generateRandomUUID();
    this.controller.onLoad((error: BusinessError) => {
      // Pen Kit reports successful loads with a nonempty message as well.
      if (error && error.code) { this.error = error.message; return; }
      this.ready = true;
    });
  }
  private initialize(): void {
    try { this.controller.load(this.notePath); }
    catch (error) { this.error = (error as Error).message; }
  }
  private async add(): Promise<void> {
    if (!this.ready || this.draft.saving) { return; }
    this.error = '';
    this.draft.saving = true;
    let pixel: image.PixelMap | undefined;
    try {
      const range = this.controller.getContentRange();
      if (range.right <= range.left || range.bottom <= range.top) { throw new Error(t('请先在画板上绘制内容。')); }
      // Export native ink directly, excluding the system brush toolbar and other controls.
      pixel = await this.controller.getThumbnail(range);
      await this.onAdd(pixel);
    } catch (error) { this.error = (error as Error).message; }
    finally { try { await pixel?.release(); } finally { this.draft.saving = false; } }
  }
  @Builder
  private header() {
    Stack() {
      Text(t('画板')).fontFamily(this.appearance.fontFamily).fontSize(Font.title).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
      Row() {
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('取消'), compId: 'drawing-cancel',
          fill: $r('app.color.surface'), material: this.appearance.control, tint: $r('sys.color.font_primary'),
          disabled: this.draft.saving, onTap: this.onClose })
        Blank()
        Button() {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(14).fontColor([this.appearance.onAccent])
            Text(this.draft.saving ? t('添加中…') : t('添加')).fontFamily(this.appearance.fontFamily)
              .fontSize(Font.small).fontWeight(FontWeight.Medium).fontColor(this.appearance.onAccent)
          }
        }.id('drawing-add').attributeModifier(Btn.primary).height(44).padding({ left: 16, right: 16 })
          .systemMaterial(this.appearance.accentControl).accessibilityText(t('添加到消息'))
          .enabled(this.ready && !this.draft.saving).onClick(() => this.add())
      }.width('100%')
    }.width('100%').height(52).padding({ left: 4, right: 4 })
  }
  build() {
    Navigation() {
      Column({ space: Space.sm }) {
        if (this.supported) {
          Column() {
            HandwriteComponent({ handwriteController: this.controller, defaultPenType: PenType.BALLPOINT_PEN,
              hiddenTools: { hiddenOptionalTools: [HiddenToolType.MOSAIC, HiddenToolType.LASER] },
              onInit: () => this.initialize() })
          }.id('drawing-canvas').width('100%').layoutWeight(1).backgroundColor('#ffffff').enabled(!this.draft.saving)
            .borderRadius(Radius.xl).clip(true).border({ width: 0.5, color: $r('app.color.divider') })
        } else {
          Text(t('此设备不支持系统手写画板。')).fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        }
        if (this.error) {
          Text(this.error).id('drawing-error').fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.danger')).width('100%')
        }
      }.width('100%').height('100%').padding({ top: Space.sm })
    }
      // Button materials require the native navigation title-bar context.
      .title({ builder: this.header, height: 52 }, { barStyle: BarStyle.STANDARD,
        backgroundColor: Color.Transparent, backgroundEffect: { radius: 0, color: Color.Transparent } })
      .hideBackButton(true).titleMode(NavigationTitleMode.Mini).hideToolBar(true).mode(NavigationMode.Stack)
      .width('100%').height('100%').padding({ left: Space.md, right: Space.md,
        top: this.insetTop + 4, bottom: this.insetBottom + Space.sm })
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
