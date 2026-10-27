import { AppearanceStyle } from '../common/AppearanceStyle';
import { IconButton } from '../common/Widgets';
import { systemInsets } from '../common/Theme';
import { t } from '../model/I18n';
import { PreviewSurface } from './PreviewSurface';

@Component
export struct PreviewFullscreen {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop title: string = '';
  surface?: PreviewSurface;
  onClose: () => void = () => {};
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  private mounted: boolean = false;
  private host(): PreviewSurface {
    if (!this.surface) { throw new Error('Fullscreen preview surface is missing'); }
    return this.surface;
  }
  aboutToAppear(): void {
    this.mounted = true;
    systemInsets(this.getUIContext()).then((insets: number[]) => {
      if (this.mounted) { this.insetTop = insets[0]; this.insetBottom = insets[1]; }
    });
  }
  aboutToDisappear(): void { this.mounted = false; this.surface?.exitFullscreen(); }
  build() {
    Column() {
      Row() {
        Text(this.title).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('退出全屏'), compId: 'exit-fullscreen-preview', onTap: this.onClose })
      }.width('100%').height(56).padding({ left: 16, right: 8 })
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
      Column() {
        NodeContainer(this.host().fullscreenMount).width('100%').height('100%')
      }.width('100%').layoutWeight(1).clip(true)
        .onAreaChange((_old: Area, next: Area) => { this.host().resizeFullscreen(Math.max(0, Number(next.height))); })
    }.id('fullscreen-preview').width('100%').height('100%').backgroundColor($r('app.color.surface'))
      .padding({ top: this.insetTop, bottom: this.insetBottom })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
