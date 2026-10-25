import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { Banner, GroupCard, IconButton, NavRow, SectionHeader } from '../common/Widgets';
import { t } from '../model/I18n';
import { FeedbackAttachment, FeedbackFilter, FeedbackItem, FeedbackType, FeedbackTypeFilter, FeedbackUpload } from '../model/Feedback';
import { FeedbackService, feedbackService } from '../services/FeedbackService';
import { FeedbackFiles } from '../services/FeedbackFiles';
import { exportFile } from '../services/NativeActions';

@Component
export struct FeedbackPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @State private service: FeedbackService = feedbackService;
  @State private history: boolean = false;
  @State private fileBusy: boolean = false;
  @State private showPreview: boolean = false;
  @State private previewPath: string = '';
  @State private previewText: string = '';
  @State private previewName: string = '';
  @State private previewImage: boolean = false;
  onClose: () => void = () => {};
  private visible: boolean = false;

  aboutToAppear(): void { this.visible = true; this.start(); }
  aboutToDisappear(): void { this.visible = false; this.cleanPreview(); }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private locked(): boolean { return this.service.busy || this.fileBusy; }
  private draftLocked(): boolean { return this.locked() || this.service.uncertain || !!this.service.attachmentFeedbackId; }
  private async start(): Promise<void> {
    await this.service.initialize(this.context());
    if (this.service.uncertain || this.service.attachmentFeedbackId) { this.history = true; await this.service.load('all', false, 'all'); }
  }
  private back(): void {
    if (this.service.detail) { this.service.detail = null; }
    else if (this.history) { this.history = false; }
    else { this.onClose(); }
  }
  private async showHistory(): Promise<void> {
    this.history = true; this.service.detail = null; await this.service.load('all', false, 'all');
  }
  private async submit(): Promise<void> {
    this.getUIContext().getFocusController().clearFocus();
    if (await this.service.submit() && this.visible) { await this.showHistory(); }
  }
  private async open(id: string): Promise<void> {
    await this.service.open(id);
    if (this.visible && this.history && this.service.detail?.id === id) { this.service.markViewed(this.service.detail); }
  }
  private confirmRetry(): void {
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface,
      title: t('确认近期记录中没有这条反馈？'),
      message: t('提交超时后仍可能已保存。请先刷新“我的反馈”并查看近期记录，确认后才允许重新提交。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('已核对，返回填写'), action: () => { this.service.resolveUncertain(); this.history = false; this.service.detail = null; } }
    });
  }
  private date(value: string): string { return new Date(value).toLocaleString(); }
  private status(item: FeedbackItem): string { return item.status === 'handled' ? t('已处理') : t('待处理'); }
  private typeName(type: FeedbackType): string { return type === 'bug' ? t('功能异常') : type === 'suggestion' ? t('产品建议') : t('其他'); }
  private uploadState(file: FeedbackUpload): string {
    return file.state === 'uploaded' ? t('已上传') : file.state === 'uncertain' ? t('结果待核对') : file.state === 'failed' ? t('上传失败') : t('等待上传');
  }
  private async pickImages(): Promise<void> {
    if (this.draftLocked()) { return; }
    this.fileBusy = true; this.service.error = '';
    let files: FeedbackUpload[] = [];
    try {
      files = await FeedbackFiles.pickImages(3 - this.service.uploads.filter((file: FeedbackUpload) => file.kind === 'image').length);
      if (this.visible) { this.service.addUploads(files); files = []; }
    } catch (_) { this.service.error = t('无法添加图片，请选择不超过 5 MiB、2,400 万像素的图片。'); }
    finally {
      try { for (const file of files) { await FeedbackFiles.remove(file.path); } }
      catch (_) { this.service.error = t('无法移除本机附件，请稍后重试。'); }
      this.fileBusy = false;
    }
  }
  private async setLogAttached(enabled: boolean): Promise<void> {
    if (this.draftLocked()) { return; }
    const existing = this.service.uploads.find((file: FeedbackUpload) => file.kind === 'log');
    // Native select() synchronization may also emit onChange. Apply the requested state, never toggle it blindly.
    if (enabled === !!existing) { return; }
    if (!enabled && existing) { await this.service.removeUpload(existing.localId); return; }
    this.fileBusy = true; this.service.error = '';
    let file: FeedbackUpload | undefined;
    try {
      file = await FeedbackFiles.saveLog(FeedbackFiles.collectLog());
      if (this.visible) { this.service.addUploads([file]); file = undefined; }
    } catch (_) { this.service.error = t('无法整理最近的诊断日志，请稍后重试。'); }
    finally {
      try { if (file) { await FeedbackFiles.remove(file.path); } }
      catch (_) { this.service.error = t('无法移除本机附件，请稍后重试。'); }
      this.fileBusy = false;
    }
  }
  private async preview(item: FeedbackItem, file: FeedbackAttachment): Promise<void> {
    if (this.locked()) { return; }
    this.fileBusy = true; this.service.error = '';
    try {
      const bytes = await this.service.attachmentBytes(item, file);
      if (!this.visible) { return; }
      this.previewPath = await FeedbackFiles.cache(file, bytes);
      this.previewImage = file.kind === 'image'; this.previewName = file.filename;
      this.previewText = file.kind === 'log' ? FeedbackFiles.logText(bytes).slice(0, 80000) : '';
      this.showPreview = true;
    } catch (error) { this.service.error = (error as Error).message; }
    finally { this.fileBusy = false; }
  }
  private async cleanPreview(): Promise<void> {
    const path = this.previewPath; this.previewPath = ''; this.previewText = '';
    if (path) {
      try { await FeedbackFiles.remove(path); }
      catch (_) { this.service.error = t('无法移除本机附件，请稍后重试。'); }
    }
  }
  private async savePreview(): Promise<void> {
    if (this.fileBusy || !this.previewPath) { return; }
    this.fileBusy = true;
    try { await exportFile(this.context(), this.previewPath, this.previewName); }
    catch (_) { this.service.error = t('无法保存附件副本，请重试。'); }
    finally { this.fileBusy = false; }
  }
  private confirmDelete(item: FeedbackItem, file: FeedbackAttachment): void {
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('删除这份附件？'), message: file.filename,
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('删除'), fontColor: $r('app.color.danger'), action: () => this.service.deleteAttachment(item, file) } });
  }
  private confirmUploadRetry(): void {
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('确认附件尚未上传？'),
      message: t('请先刷新附件并核对。上传超时后可能已经保存，重复上传会占用附件数量。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('已核对，允许重试'), action: () => this.service.resolveUploadUncertainty() } });
  }
  private confirmClearTask(): void {
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('结束这次附件任务？'),
      message: t('已提交的正文和附件会保留在“我的反馈”。未上传的附件将从本机任务中移除。'),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('结束任务'), action: () => this.service.clearUploadTask() } });
  }

  @Builder
  header() {
    Row({ space: Space.sm }) {
      IconButton({ icon: $r('sys.symbol.chevron_left'), label: t('返回'), fill: $r('app.color.surface'), compId: 'feedback-nav-back', onTap: () => this.back() })
      Text(this.history ? t('我的反馈') : t('反馈与建议')).fontFamily(this.appearance.fontFamily).fontSize(19).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1)
      IconButton({ icon: $r('sys.symbol.clock'), label: t('我的反馈'), fill: $r('app.color.surface'), compId: 'feedback-history-tab', disabled: this.locked(), onTap: () => this.showHistory() })
      IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭'), fill: $r('app.color.surface'), compId: 'feedback-close', onTap: () => this.onClose() })
    }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.sm })
  }
  @Builder
  label(text: string, required: boolean = false) {
    Text() {
      Span(text)
      if (required) { Span(' *').fontColor($r('app.color.danger')) }
    }.fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_secondary')).width('100%')
      .padding({ left: Space.md, top: 6, bottom: 2 })
  }
  @Builder
  typeChip(type: FeedbackType) {
    Button(this.typeName(type)).id('feedback-type-' + type).fontFamily(this.appearance.fontFamily)
      .attributeModifier(this.service.type === type ? Btn.tonalSmall : Btn.plainSmall).enabled(!this.draftLocked())
      .accessibilityText(this.typeName(type) + (this.service.type === type ? t('，已选中') : ''))
      .onClick(() => { this.service.type = type; })
  }
  @Builder
  compose() {
    this.label(t('反馈类型'))
    Row({ space: Space.sm }) { this.typeChip('bug'); this.typeChip('suggestion'); this.typeChip('other') }.width('100%')
    this.label(t('反馈内容'), true)
    TextArea({ text: this.service.body, placeholder: t('请描述遇到的问题或你的建议') })
      .id('feedback-body').fontFamily(this.appearance.fontFamily).fontSize(Font.body).height(140).maxLength(5000).showCounter(true)
      .borderRadius(Radius.lg).backgroundColor($r('app.color.surface')).padding(Space.md)
      .enabled(!this.draftLocked()).onChange((value: string) => { this.service.body = value; })
    this.label(t('添加图片（最多 3 张，每张 5 MiB）'))
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.service.uploads.filter((file: FeedbackUpload) => file.kind === 'image'), (file: FeedbackUpload) => {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image('file://' + file.path).width(76).height(76).objectFit(ImageFit.Cover).borderRadius(Radius.md)
          IconButton({ icon: $r('sys.symbol.xmark'), label: t('移除图片'), diameter: 28, iconSize: 12, fill: $r('app.color.surface'),
            disabled: this.draftLocked(), compId: 'feedback-remove-' + file.localId, onTap: () => this.service.removeUpload(file.localId) })
        }.margin({ right: Space.sm, bottom: Space.sm })
      }, (file: FeedbackUpload) => file.localId)
      if (this.service.uploads.filter((file: FeedbackUpload) => file.kind === 'image').length < 3) {
        Button({ type: ButtonType.Normal }) { SymbolGlyph($r('sys.symbol.plus')).fontSize(24).fontColor([$r('app.color.text_secondary')]) }
          .id('feedback-add-images').width(76).height(76).borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
          .accessibilityText(t('添加图片')).enabled(!this.draftLocked()).onClick(() => this.pickImages())
      }
    }.width('100%')
    this.label(t('联系方式'))
    TextInput({ text: this.service.contact, placeholder: t('邮箱或其他联系方式（可选）') })
      .id('feedback-contact').fontFamily(this.appearance.fontFamily).height(44).maxLength(200).borderRadius(22)
      .backgroundColor($r('app.color.surface')).enabled(!this.draftLocked()).onChange((value: string) => { this.service.contact = value; })
    Row({ space: Space.sm }) {
      Checkbox({ name: 'feedback-log' }).select(this.service.uploads.some((file: FeedbackUpload) => file.kind === 'log'))
        .id('feedback-log-checkbox').width(20).height(20).selectedColor(this.appearance.accent)
        .enabled(!this.draftLocked()).onChange((enabled: boolean) => this.setLogAttached(enabled))
      Text(t('附加最近日志，帮助定位问题')).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_primary')).layoutWeight(1)
        .onClick(() => this.setLogAttached(!this.service.uploads.some((file: FeedbackUpload) => file.kind === 'log')))
      if (this.fileBusy) { LoadingProgress().width(20).height(20) }
    }.width('100%').constraintSize({ minHeight: 44 }).margin({ top: Space.xs })
    Text(t('仅发送你填写的内容和所选附件，请勿包含密码、密钥或聊天隐私。最近日志仅在勾选后附加。'))
      .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(19).fontColor($r('app.color.text_tertiary')).width('100%')
  }
  @Builder
  attachmentPreview() {
    Column({ space: Space.md }) {
      if (this.previewImage) {
        Image('file://' + this.previewPath).width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
      } else {
        Scroll() { Text(this.previewText).fontFamily(this.appearance.fontFamily).fontSize(Font.small).copyOption(CopyOptions.InApp).width('100%') }.layoutWeight(1)
        Text(t('预览最多显示 80,000 字符；保存副本可查看完整文件。')).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
      }
      Button(t('保存副本')).id('feedback-save-attachment').attributeModifier(Btn.tonal).enabled(!this.fileBusy).onClick(() => this.savePreview())
    }.width('100%').height('100%').padding(Space.page)
  }
  @Builder
  filterButton(label: string, filter: FeedbackFilter) {
    Button(label).fontFamily(this.appearance.fontFamily).attributeModifier(this.service.filter === filter ? Btn.tonalSmall : Btn.textSmall)
      .id('feedback-filter-' + filter).enabled(!this.locked()).onClick(() => this.service.load(filter))
  }
  @Builder
  typeFilterButton(label: string, type: FeedbackTypeFilter) {
    Button(label).fontFamily(this.appearance.fontFamily).attributeModifier(this.service.typeFilter === type ? Btn.tonalSmall : Btn.textSmall)
      .id('feedback-type-filter-' + type).enabled(!this.locked()).onClick(() => this.service.load(this.service.filter, false, type))
  }
  @Builder
  list() {
    Flex({ wrap: FlexWrap.Wrap }) {
      this.filterButton(t('全部'), 'all')
      this.filterButton(t('待处理（{0}）', [this.service.counts.new]), 'new')
      this.filterButton(t('已处理（{0}）', [this.service.counts.handled]), 'handled')
    }.width('100%')
    Flex({ wrap: FlexWrap.Wrap }) {
      this.typeFilterButton(t('全部类型'), 'all'); this.typeFilterButton(t('功能异常'), 'bug')
      this.typeFilterButton(t('产品建议'), 'suggestion'); this.typeFilterButton(t('其他'), 'other')
    }.width('100%')
    Button(t('刷新')).id('feedback-refresh').fontFamily(this.appearance.fontFamily).attributeModifier(Btn.text)
      .enabled(!this.locked()).onClick(() => this.service.load())
    if (this.service.items.length === 0 && !this.locked() && !this.service.error) {
      Text(t('暂无反馈记录')).id('feedback-empty').fontFamily(this.appearance.fontFamily).fontSize(Font.body)
        .fontColor($r('app.color.text_secondary')).padding(Space.xl)
    }
    ForEach(this.service.items, (item: FeedbackItem) => {
      GroupCard() {
        NavRow({ title: item.body, subtitle: this.typeName(item.type) + ' · ' + this.status(item) + ' · ' + this.date(item.createdAt),
          value: this.service.hasNewReply(item) ? t('有新回复') : item.reply ? t('已回复') : t('尚未回复'),
          compId: 'feedback-item-' + item.id, disabled: this.locked(), onTap: () => this.open(item.id) })
      }
    }, (item: FeedbackItem) => item.id)
    if (this.service.nextCursor) {
      Button(t('加载更多')).id('feedback-load-more').fontFamily(this.appearance.fontFamily).attributeModifier(Btn.tonal)
        .enabled(!this.locked()).onClick(() => this.service.load(this.service.filter, true))
    }
    Text(t('匿名凭证仅保存在本机，用于查看反馈和回复；卸载或清除数据后无法找回。不提供推送通知，请主动查看“我的反馈”。'))
      .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(20).fontColor($r('app.color.text_tertiary')).width('100%').margin({ top: Space.lg })
  }
  @Builder
  uploadTask() {
    SectionHeader({ title: t('附件任务'), caption: t('正文已经提交，附件结果单独记录。') })
    ForEach(this.service.uploads, (file: FeedbackUpload) => {
      GroupCard() {
        Column({ space: Space.sm }) {
          Text(file.filename).fontSize(Font.small).fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_primary')).width('100%')
          Text(this.uploadState(file)).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
          if (file.error) { Banner({ text: file.error }) }
        }.padding(Space.md).width('100%')
      }
    }, (file: FeedbackUpload) => file.localId)
    if (this.service.uploads.some((file: FeedbackUpload) => file.state === 'uncertain')) {
      Button(t('刷新附件并核对')).id('feedback-reconcile-uploads').attributeModifier(Btn.tonal).enabled(!this.locked()).onClick(() => this.service.reconcileUploads())
      Button(t('已核对，允许重试')).id('feedback-resolve-uploads').attributeModifier(Btn.text)
        .enabled(!this.locked() && this.service.uploadsChecked).onClick(() => this.confirmUploadRetry())
    } else {
      Button(t('继续附件任务')).id('feedback-retry-uploads').attributeModifier(Btn.tonal).enabled(!this.locked()).onClick(() => this.service.retryUploads())
    }
    Button(t('结束任务')).attributeModifier(Btn.text).enabled(!this.locked()).onClick(() => this.confirmClearTask())
  }
  @Builder
  detail(item: FeedbackItem) {
    Row() {
      Button(t('返回列表')).id('feedback-back').attributeModifier(Btn.text).enabled(!this.locked()).onClick(() => { this.service.detail = null; })
      Blank()
      Button(t('刷新')).id('feedback-detail-refresh').attributeModifier(Btn.text).enabled(!this.locked()).onClick(() => this.open(item.id))
    }.width('100%')
    SectionHeader({ title: this.typeName(item.type) + ' · ' + this.status(item), caption: this.date(item.createdAt) })
    GroupCard() {
      Column({ space: Space.md }) {
        Text(item.body).id('feedback-detail-body').fontFamily(this.appearance.fontFamily).fontSize(Font.body)
          .fontColor($r('app.color.text_primary')).width('100%').copyOption(CopyOptions.InApp).lineHeight(24)
        if (item.contact) { Text(t('联系方式：{0}', [item.contact])).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_secondary')).width('100%') }
      }.width('100%').padding(Space.lg)
    }
    if (item.attachments.length) {
      SectionHeader({ title: t('附件') })
      ForEach(item.attachments, (file: FeedbackAttachment) => {
        GroupCard() {
          Row() {
            Column({ space: 4 }) {
              Text(file.filename).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_primary')).maxLines(2)
              Text((file.size / 1024).toFixed(1) + ' KiB').fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button(t('查看')).attributeModifier(Btn.textSmall).enabled(!this.locked()).onClick(() => this.preview(item, file))
            IconButton({ icon: $r('sys.symbol.trash'), label: t('删除附件'), disabled: this.locked(), onTap: () => this.confirmDelete(item, file) })
          }.width('100%').padding(Space.md)
        }
      }, (file: FeedbackAttachment) => file.id)
    }
    if (this.service.uncertain && this.service.uploads.length && item.body === this.service.body.trim() && item.contact === this.service.contact.trim() && item.type === this.service.type) {
      Button(t('将所选附件上传到这条反馈')).id('feedback-recover-attachments').attributeModifier(Btn.tonal).enabled(!this.locked())
        .onClick(() => this.service.attachToRecoveredFeedback(item))
    }
    SectionHeader({ title: t('开发者回复') })
    GroupCard() {
      Column({ space: Space.md }) {
        Text(item.reply ? item.reply.body : t('尚未回复')).id('feedback-reply').fontFamily(this.appearance.fontFamily).fontSize(Font.body)
          .fontColor($r('app.color.text_primary')).width('100%').copyOption(CopyOptions.InApp).lineHeight(24)
        if (item.reply) { Text(this.date(item.reply.updatedAt)).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%') }
      }.width('100%').padding(Space.lg)
    }
  }
  build() {
    Column() {
      this.header()
      Scroll() {
        Column({ space: this.history ? Space.md : Space.sm }) {
          if (this.service.error) { Banner({ text: this.service.error, compId: 'feedback-error' }) }
          if (this.service.notice) { Banner({ text: this.service.notice, danger: false }) }
          if (!this.service.ready && !this.service.busy) { Button(t('重试')).attributeModifier(Btn.tonal).onClick(() => this.start()) }
          if (this.service.busy) { LoadingProgress().width(24).height(24).id('feedback-loading') }
          if (this.service.progress) { Text(this.service.progress).fontSize(Font.small).fontColor($r('app.color.text_secondary')) }
          if (this.service.uncertain) {
            Banner({ text: t('提交结果尚未确认，请先查询近期反馈，避免重复提交。'), compId: 'feedback-uncertain' })
            Button(t('查询近期反馈')).id('feedback-check-recent').attributeModifier(Btn.tonal).enabled(!this.locked()).onClick(() => this.showHistory())
            Button(t('已核对近期记录')).id('feedback-resolve').attributeModifier(Btn.text).enabled(!this.locked()).onClick(() => this.confirmRetry())
          }
          if (this.service.attachmentFeedbackId) { this.uploadTask() }
          if (this.history) {
            if (this.service.detail) { this.detail(this.service.detail) } else { this.list() }
          } else { this.compose() }
        }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      if (!this.history) {
        Row() {
          Button(this.service.busy ? t('正在提交…') : t('提交')).id('feedback-submit').fontFamily(this.appearance.fontFamily).attributeModifier(Btn.primary)
            .width('100%').enabled(this.service.ready && !this.draftLocked() && this.service.body.trim().length > 0).onClick(() => this.submit())
        }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.md })
      }
    }.width('100%').height('100%')
      .bindSheet($$this.showPreview, this.attachmentPreview(), { title: { title: this.previewName }, height: SheetSize.LARGE, dragBar: true,
        systemMaterial: this.appearance.surface, onDisappear: () => this.cleanPreview() })
  }
}
