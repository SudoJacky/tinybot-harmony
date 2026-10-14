import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { PublishedPreview } from '../model/PublishedPreview';
import { UiSavedState, UiValues } from '../model/InteractiveUi';
import { Attachments } from '../services/Attachments';
import { Btn, Radius, Space } from '../common/Theme';
import { InteractiveAnswer } from './InteractiveAnswer';
import { UiPresentation } from '../model/UiPresentation';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Component
export struct PublishedPreviewCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  presentation?: UiPresentation;
  @Prop @Watch('revisionChanged') preview: PublishedPreview;
  @Prop available: boolean = false;
  saved: UiSavedState[] = [];
  onInteract: (key: string, values: UiValues, action: string) => Promise<UiValues> = async () => { throw new Error('Preview interaction handler missing'); };
  @State private expanded: boolean = false;
  @State private imageError: boolean = false;
  private superseded: boolean = false;
  aboutToAppear(): void { this.superseded = this.preview.superseded; this.expanded = !this.superseded; }
  private revisionChanged(): void {
    if (this.preview.superseded && !this.superseded) { this.expanded = false; }
    this.superseded = this.preview.superseded;
  }
  private thumbnailSize(): ImageSourceSize {
    const screenshot = this.preview.screenshot;
    if (!screenshot) { throw new Error('Preview thumbnail requires a screenshot'); }
    const scale = Math.min(264 / screenshot.width, 192 / screenshot.height);
    return { width: Math.max(1, Math.round(screenshot.width * scale)), height: Math.max(1, Math.round(screenshot.height * scale)) };
  }
  build() {
    Column({ space: Space.sm }) {
      if (this.preview.superseded || !this.expanded) {
        Row({ space: Space.md }) {
          if (this.preview.screenshot && !this.imageError) {
            Image('file://' + Attachments.path(this.preview.screenshot.image)).width(88).height(64).objectFit(ImageFit.Contain)
              .sourceSize(this.thumbnailSize()).borderRadius(Radius.sm)
              .accessibilityText(this.preview.title).onError((error) => {
                this.imageError = true;
                hilog.error(0x0000, 'TinybotPreview', 'thumbnail id=%{public}s error=%{public}s', this.preview.id, error.message);
              })
          }
          Column({ space: 4 }) {
            Text(this.preview.title).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text(this.preview.superseded ? t('历史版本') : this.preview.path).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
            if (this.imageError) { Text(t('预览截图加载失败')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.danger')) }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button(this.expanded ? t('收起预览') : t('展开预览')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
            .id('preview-toggle-' + this.preview.id).onClick(() => { this.expanded = !this.expanded; })
        }.width('100%').padding(12).borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
      }
      if (this.expanded) {
        InteractiveAnswer({ content: this.preview.content, step: this.preview.step, surfaceOffset: this.preview.surfaceOffset,
          saved: this.saved, presentation: this.presentation, available: this.available, onInteract: this.onInteract, selectable: false })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
