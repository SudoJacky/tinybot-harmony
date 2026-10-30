import { common } from '@kit.AbilityKit';
import { Diagnostics } from '../model/Diagnostics';
import { LogError } from '../model/DiagnosticLog';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { BottomBar, Banner } from '../common/Widgets';
import { Btn } from '../common/Theme';
import { MessageData } from '../model/Conversation';
import { ConversationShareData, selectedConversation, conversationMarkdown, conversationFileName } from '../model/ConversationShare';
import { ConversationSection, conversationSections } from '../model/ConversationExport';
import { exportMetadata, stampMarkdown } from '../model/ExportMetadata';
import { t } from '../model/I18n';
import { writeBytes } from '../services/Attachments';
import { conversationImage } from '../services/ConversationImageExport';
import { hostedPrivacy } from '../services/HostedPrivacy';
import { exportFile, shareFile } from '../services/NativeActions';
import { ConversationExportSection } from './ConversationExportSection';
import { MarkdownView } from './MarkdownView';

@Component
export struct ConversationSharePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  data: ConversationShareData = { thread: { id: '', title: '', updatedAt: 0, messages: [] }, profiles: [] };
  @State private selectedIds: string[] = [];
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private previewPath: string = '';
  @State private previewRatio: number = 1;
  private mounted: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.selectedIds = this.data.thread.messages.map((message) => message.id);
  }
  aboutToDisappear(): void {
    this.mounted = false;
    const path = this.previewPath;
    this.previewPath = '';
    this.removeTemporary(path).catch((error: Error) => Diagnostics.log('warn', 'export', 'cleanup_failed', undefined, error));
  }
  private async removeTemporary(path: string): Promise<void> {
    if (path && await fs.access(path)) { await fs.unlink(path); }
  }
  private ensureActive(): void {
    if (!this.mounted || !hostedPrivacy.allowed) {
      const error = new Error(t('分享已取消')) as LogError; error.code = 'CANCELLED'; throw error;
    }
  }
  private select(id: string, checked: boolean): void {
    if (this.busy) { return; }
    this.selectedIds = checked ? this.selectedIds.filter((item) => item !== id).concat(id) : this.selectedIds.filter((item) => item !== id);
  }
  private selectAll(): void {
    if (this.busy) { return; }
    this.selectedIds = this.selectedIds.length === this.data.thread.messages.length ? [] : this.data.thread.messages.map((message) => message.id);
  }
  private summary(message: MessageData): string {
    return message.content || t('附件');
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }

  @Builder
  imageSection(section: ConversationSection) { ConversationExportSection({ section: section }) }

  private async generateImage(): Promise<void> {
    if (this.busy || !this.selectedIds.length) { return; }
    this.busy = true; this.error = '';
    let temporary = '';
    try {
      this.ensureActive();
      const thread = selectedConversation(this.data.thread, this.selectedIds);
      const context = this.context();
      const ui = this.getUIContext();
      temporary = await conversationImage(context, conversationSections(thread, this.data.profiles), (section: ConversationSection) => {
        this.ensureActive();
        return ui.getComponentSnapshot().createFromBuilder(() => { this.imageSection(section); }, 0, true,
          { scale: 720 / ui.vp2px(360), waitUntilRenderFinished: true });
      }, context.resourceManager.getColorSync($r('app.color.page_background').id));
      this.ensureActive();
      const source = image.createImageSource(temporary);
      try {
        const info = await source.getImageInfo();
        this.ensureActive();
        this.previewRatio = info.size.width / info.size.height;
      } finally { await source.release(); }
      this.ensureActive();
      this.previewPath = temporary; temporary = '';
    } catch (error) {
      if ((error as LogError).code !== 'CANCELLED') { Diagnostics.log('error', 'export', 'preview_failed', undefined, error as Error); }
      if (this.mounted) { this.error = t('导出图片失败：{0}', [(error as Error).message || String(error)]); }
    } finally {
      try { await this.removeTemporary(temporary); }
      catch (error) {
        Diagnostics.log('warn', 'export', 'cleanup_failed', undefined, error as Error);
        if (this.mounted) { this.error = (error as Error).message; }
      }
      finally { this.busy = false; }
    }
  }
  private async reselect(): Promise<void> {
    if (this.busy) { return; }
    const path = this.previewPath;
    this.previewPath = ''; this.error = '';
    try { await this.removeTemporary(path); }
    catch (error) {
      Diagnostics.log('warn', 'export', 'cleanup_failed', undefined, error as Error);
      this.error = (error as Error).message;
    }
  }
  private async outputImage(share: boolean): Promise<void> {
    if (this.busy || !this.previewPath) { return; }
    this.busy = true; this.error = '';
    try {
      this.ensureActive();
      const name = conversationFileName(this.data.thread.title, 'png');
      if (share) { await shareFile(this.context(), this.previewPath, name); }
      else { await exportFile(this.context(), this.previewPath, name); }
    } catch (error) {
      if ((error as LogError).code !== 'CANCELLED') {
        Diagnostics.log('error', 'export', share ? 'share_failed' : 'save_failed', { format: 'image' }, error as Error);
      }
      if (this.mounted) { this.error = (error as Error).message; }
    }
    finally { this.busy = false; }
  }
  private async outputMarkdown(share: boolean): Promise<void> {
    if (this.busy || !this.selectedIds.length) { return; }
    this.busy = true; this.error = '';
    let temporary = '';
    try {
      this.ensureActive();
      const thread = selectedConversation(this.data.thread, this.selectedIds);
      const context = this.context();
      const id = util.generateRandomUUID();
      const text = stampMarkdown(conversationMarkdown(thread), exportMetadata(id));
      temporary = context.cacheDir + '/conversation-' + id + '.md';
      await writeBytes(temporary, new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer);
      this.ensureActive();
      const name = conversationFileName(thread.title, 'md');
      if (share) { await shareFile(context, temporary, name); }
      else { await exportFile(context, temporary, name); }
    } catch (error) {
      if ((error as LogError).code !== 'CANCELLED') {
        Diagnostics.log('error', 'export', share ? 'share_failed' : 'save_failed', { format: 'markdown' }, error as Error);
      }
      if (this.mounted) { this.error = (error as Error).message; }
    }
    finally {
      try { await this.removeTemporary(temporary); }
      catch (error) {
        Diagnostics.log('warn', 'export', 'cleanup_failed', undefined, error as Error);
        if (this.mounted) { this.error = (error as Error).message; }
      }
      finally { this.busy = false; }
    }
  }
  @Builder
  markdownMenu() {
    Menu() {
      MenuItem({ content: t('保存 Markdown') }).onClick(() => this.outputMarkdown(false))
      MenuItem({ content: t('分享 Markdown') }).onClick(() => this.outputMarkdown(true))
    }
  }
  @Builder
  messageRow(message: MessageData) {
    Row({ space: 10 }) {
      Checkbox().select(this.selectedIds.includes(message.id)).selectedColor($r('app.color.accent'))
        .enabled(!this.busy).id('share-message-' + message.id)
        .accessibilityText(t('选择消息：{0}', [this.summary(message).slice(0, 60)]))
        .onClick(() => this.select(message.id, !this.selectedIds.includes(message.id)))
      Column({ space: 8 }) {
        Text(message.role === 'user' ? t('用户') : 'Tinybot').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
        MarkdownView({ content: this.summary(message), fontSize: 15, selectable: false })
        if (message.attachments?.length) {
          Text(message.attachments.map((file) => file.name).join(' · ')).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(16).borderRadius(18)
        .backgroundColor(message.role === 'user' ? this.appearance.userBubble : $r('app.color.surface'))
    }.width('100%').alignItems(VerticalAlign.Top)
  }
  build() {
    NavDestination() {
      Column() {
        if (this.previewPath) {
          Scroll() {
            Image('file://' + this.previewPath).width('100%').aspectRatio(this.previewRatio)
              .objectFit(ImageFit.Contain).borderRadius(20).id('conversation-share-preview')
          }.layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).align(Alignment.Top)
        } else {
          Row({ space: 8 }) {
            Checkbox().select(this.selectedIds.length === this.data.thread.messages.length)
              .selectedColor($r('app.color.accent')).enabled(!this.busy).id('share-select-all')
              .accessibilityText(t('全选')).onClick(() => this.selectAll())
            Text(t('全选')).fontSize(15).fontColor($r('app.color.text_primary'))
            Blank()
            Text(t('已选 {0} 条消息', [String(this.selectedIds.length)])).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.width('100%').padding({ left: 16, right: 20, bottom: 12 })
          List({ space: 16 }) {
            ForEach(this.data.thread.messages, (message: MessageData) => {
              ListItem() { this.messageRow(message) }
            }, (message: MessageData) => message.id)
          }.layoutWeight(1).width('100%').padding({ left: 12, right: 16 }).id('share-message-list')
        }
        if (this.error) { Banner({ text: this.error }) }
        BottomBar() {
          Row({ space: 12 }) {
            if (this.previewPath) {
              Button(t('分享')).layoutWeight(1).height(48).backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.accent')).enabled(!this.busy).id('share-preview-image').onClick(() => this.outputImage(true))
              Button(t('保存图片')).layoutWeight(2).attributeModifier(Btn.primary)
                .enabled(!this.busy).id('save-preview-image').onClick(() => this.outputImage(false))
            } else {
              Button('Markdown').layoutWeight(1).height(48).backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.accent')).enabled(!this.busy && this.selectedIds.length > 0)
                .bindMenu(this.markdownMenu).id('share-markdown')
              Button(this.busy ? t('处理中…') : t('生成图片')).layoutWeight(2).attributeModifier(Btn.primary)
                .enabled(!this.busy && this.selectedIds.length > 0).id('generate-share-image').onClick(() => this.generateImage())
            }
          }.width('100%')
        }
      }.width('100%').height('100%')
    }.title(t('分享会话'), { systemMaterial: this.appearance.control })
      .backgroundColor($r('app.color.page_background'))
      .onBackPressed(() => {
        if (this.busy) { return true; }
        if (this.previewPath && !this.busy) { this.reselect(); return true; }
        return false;
      })
  }
}
