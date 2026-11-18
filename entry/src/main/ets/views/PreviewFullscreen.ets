import { FrameCallback } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { PreviewFullscreenMotion } from '../common/FullscreenTransition';
import { IconButton } from '../common/Widgets';
import { Motion, systemInsets } from '../common/Theme';
import { t } from '../model/I18n';
import { PreviewSurface } from './PreviewSurface';

class PreviewEnterFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(): void { this.action(); }
}

@Component
export struct PreviewFullscreen {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop title: string = '';
  @Prop @Watch('closingChanged') closing: boolean = false;
  surface?: PreviewSurface;
  motion?: PreviewFullscreenMotion;
  onClose: () => void = () => {};
  onClosed: () => void = () => {};
  @State private insetTop: number = 0;
  @State private insetBottom: number = 0;
  @State private progress: number = 1;
  private mounted: boolean = false;
  private host(): PreviewSurface {
    if (!this.surface) { throw new Error('Fullscreen preview surface is missing'); }
    return this.surface;
  }
  aboutToAppear(): void {
    this.mounted = true;
    const ui = this.getUIContext();
    systemInsets(ui).then((insets: number[]) => {
      if (this.mounted) { this.insetTop = insets[0]; this.insetBottom = insets[1]; }
    });
    if (this.closing) { this.onClosed(); return; }
    const motion = this.motion;
    this.progress = motion ? 0 : 1;
    if (motion) {
      ui.postFrameCallback(new PreviewEnterFrame(() => {
        if (this.mounted && !this.closing) {
          ui.animateTo({ duration: motion.duration, curve: Motion.enter }, () => { this.progress = 1; });
        }
      }));
    }
  }
  aboutToDisappear(): void { this.mounted = false; this.surface?.exitFullscreen(); }
  private closingChanged(): void {
    if (!this.mounted || !this.closing) { return; }
    if (!this.motion || this.progress === 0) { this.onClosed(); return; }
    this.getUIContext().animateTo({ duration: this.motion.duration, curve: Curve.EaseInOut,
      onFinish: () => { if (this.mounted && this.closing) { this.onClosed(); } } }, () => { this.progress = 0; });
  }
  private coverScale(): number { return 1 - (1 - this.progress) * (1 - (this.motion?.scale ?? 1)); }
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
      .scale({ x: this.coverScale(), y: this.coverScale() })
      .translate({ x: (1 - this.progress) * (this.motion?.x ?? 0), y: (1 - this.progress) * (this.motion?.y ?? 0) })
      .opacity(0.5 + 0.5 * this.progress)
  }
}
