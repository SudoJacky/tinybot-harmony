import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Radius, Space } from '../common/Theme';
import { FileAnnotationTarget, MAX_ANNOTATION_COMMENT } from '../model/FileAnnotation';
import { UiValues } from '../model/InteractiveUi';
import { t } from '../model/I18n';
import { WebAnnotationMark, WebAnnotationTarget } from '../model/WebAnnotation';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { WebUiView } from './WebUiView';

@Component
export struct HtmlFilePreview {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @Prop content: string = '';
  @Prop values: UiValues = {};
  onSave: (values: UiValues) => Promise<UiValues> = async () => { throw new Error('No save handler for this preview'); };
  threadId: string = '';
  path: string = '';
  version: string = '';
  @State private annotating: boolean = false;
  @State private selection: WebAnnotationTarget | undefined = undefined;
  @State private comment: string = '';
  @State private error: string = '';
  @State private saving: boolean = false;
  @State private revision: number = 0;
  @State private viewWidth: number = 0;
  @State private viewHeight: number = 0;

  private marks(): WebAnnotationMark[] {
    const marks: WebAnnotationMark[] = [];
    this.app.active.annotations.forEach((item, index) => {
      if (item.kind === 'element' && item.path === this.path && item.version === this.version) {
        marks.push({ number: index + 1, location: item.location });
      }
    });
    return marks;
  }

  private select(target: WebAnnotationTarget): void {
    if (!this.annotating || !this.app.canQueueInput || this.selection) { return; }
    this.selection = target;
    this.comment = ''; this.error = '';
  }

  private clear(): void {
    this.selection = undefined;
    this.comment = ''; this.error = '';
    this.revision++;
  }

  private async save(): Promise<void> {
    if (!this.selection || !this.comment.trim() || this.saving) { return; }
    this.saving = true;
    const target: FileAnnotationTarget = { kind: 'element', location: this.selection.location, excerpt: this.selection.excerpt };
    try {
      await this.app.addFileAnnotation(this.threadId, this.path, this.version, target, this.comment);
      this.clear();
    } catch (error) { this.error = (error as Error).message; }
    finally { this.saving = false; }
  }

  private editorWidth(): number { return Math.max(0, Math.min(300, this.viewWidth - 16)); }

  @Builder
  private editor(target: WebAnnotationTarget) {
    Column({ space: Space.sm }) {
      Text(target.excerpt || target.location).fontFamily(this.appearance.fontFamily).fontSize(12)
        .fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      TextArea({ text: this.comment, placeholder: t('描述修改或提出问题…') }).fontFamily(this.appearance.fontFamily)
        .maxLength(MAX_ANNOTATION_COMMENT).height(72).width('100%').onChange((value) => { this.comment = value; })
      if (this.error) {
        Text(this.error).fontSize(12).fontColor($r('app.color.danger')).width('100%')
      }
      Row({ space: Space.xs }) {
        Button(t('取消')).attributeModifier(Btn.tonalSmall).enabled(!this.saving).onClick(() => this.clear())
        Button(t('添加批注')).attributeModifier(Btn.primarySmall)
          .enabled(!this.saving && this.app.canQueueInput && this.comment.trim().length > 0).onClick(() => this.save())
      }.justifyContent(FlexAlign.End).width('100%')
    }.padding(Space.md).width(this.editorWidth()).backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
      .border({ width: 0.5, color: $r('app.color.divider') }).shadow(ShadowStyle.OUTER_DEFAULT_MD)
      .position({ x: Math.max(8, Math.min(this.viewWidth * target.x + 8, this.viewWidth - this.editorWidth() - 8)),
        y: Math.max(8, Math.min(this.viewHeight * target.y + 8, this.viewHeight - 204)) })
  }

  build() {
    Column() {
      if (this.version) {
        Row({ space: Space.sm }) {
          Button(this.annotating ? t('结束批注') : t('批注')).attributeModifier(Btn.tonalSmall)
            .id('annotate-html-preview').enabled(this.app.canQueueInput && !this.saving)
            .onClick(() => { this.annotating = !this.annotating; this.clear(); })
          if (this.annotating) {
            Text(t('点选页面元素')).fontSize(12).fontColor($r('app.color.text_secondary'))
          }
        }.height(42).width('100%').padding({ left: Space.sm })
      }
      Stack({ alignContent: Alignment.TopStart }) {
        WebUiView({ content: this.content, values: this.values, interactive: !this.annotating && !this.app.busy,
          onSave: this.onSave, viewportHeight: this.viewHeight, annotationMode: this.annotating,
          annotationMarks: this.marks(), annotationRevision: this.revision, onAnnotationTarget: (target) => this.select(target) })
        if (this.selection) { this.editor(this.selection) }
      }.width('100%').layoutWeight(1).clip(true)
        .onAreaChange((_old, area) => { this.viewWidth = Number(area.width); this.viewHeight = Number(area.height); })
    }.width('100%').height('100%')
  }
}
