import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { Banner, BottomBar, EmptyState, GroupCard, SwitchRow } from '../common/Widgets';

@Component
export struct MemoryDraftPanel {
  @ObjectLink app: ChatViewModel;
  threadId: string = '';
  messageId: string = '';
  onClose: () => void = () => {};
  @State private items: string[] = [];
  @State private selected: boolean[] = [];
  @State private loading: boolean = true;
  @State private saving: boolean = false;
  @State private global: boolean = false;
  @State private error: string = '';
  private disposed: boolean = false;
  aboutToAppear(): void { this.prepare(); }
  aboutToDisappear(): void { if (!this.disposed && this.loading) { this.app.cancelMemoryDraft(); } this.disposed = true; }
  private async prepare(): Promise<void> {
    try {
      const items = await this.app.proposeMemory(this.messageId);
      if (!this.disposed) { this.items = items; this.selected = items.map(() => true); }
    } catch (error) { if (!this.disposed) { this.error = (error as Error).message; } }
    finally { if (!this.disposed) { this.loading = false; } }
  }
  private chosen(): string[] { return this.items.filter((_item, index) => this.selected[index]); }
  private ready(): boolean { return !this.loading && !this.saving && !this.app.busy && this.chosen().length > 0 && this.chosen().every((item) => item.trim().length > 0); }
  private close(): void { if (this.saving) { return; } this.disposed = true; if (this.loading) { this.app.cancelMemoryDraft(); } this.onClose(); }
  private async save(): Promise<void> {
    if (!this.ready()) { return; }
    this.saving = true; this.error = '';
    try {
      const count = await this.app.saveMemoryDraft(this.threadId, this.messageId, this.chosen(), this.global);
      this.getUIContext().getPromptAction().showToast({ message: count ? t('已保存 {0} 条记忆', [count]) : t("这些记忆已存在，未重复添加") });
      this.onClose();
    } catch (error) { this.error = (error as Error).message; }
    finally { this.saving = false; }
  }
  @Builder
  draftCard(item: string, index: number) {
    Row({ space: Space.sm }) {
      Checkbox({ name: 'memory-' + index }).id('memory-select-' + index).select(this.selected[index])
        .shape(CheckBoxShape.CIRCLE).selectedColor($r('app.color.accent')).width(22).height(22).margin({ top: 10 })
        .enabled(!this.saving).onChange((value) => { this.selected[index] = value; this.selected = this.selected.slice(); })
      TextArea({ text: item, placeholder: t("一条简短的事实、偏好或约定") }).id('memory-draft-' + index)
        .layoutWeight(1).constraintSize({ minHeight: 72 }).maxLength(200).showCounter(true).fontSize(15).lineHeight(22)
        .backgroundColor(Color.Transparent).borderRadius(0).padding({ left: 4, right: 4, top: 8, bottom: 8 })
        .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_tertiary')).enabled(!this.saving)
        .onChange((value) => { this.items[index] = value; this.items = this.items.slice(); })
    }
    .width('100%').alignItems(VerticalAlign.Top).padding({ left: Space.md, right: Space.sm, top: 4, bottom: 4 })
    .borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: this.selected[index] ? $r('app.color.accent_container') : Color.Transparent })
    .opacity(this.selected[index] ? 1 : 0.6)
  }

  build() {
    Column() {
      if (this.loading) {
        Column({ space: Space.md }) {
          LoadingProgress().width(36).height(36).color($r('app.color.accent'))
          Text(t("正在提炼值得记住的信息…")).fontSize(15).fontColor($r('app.color.text_primary'))
          Text(t("确认前不会写入记忆")).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: Space.md }) {
            if ((this.app.active.messages.find((item) => item.id === this.messageId)?.content.length || 0) > 12000) {
              Banner({ text: t("消息较长，仅提炼了前 12000 字符，可手动补充遗漏。"), danger: false })
            }
            if (this.items.length === 0 && !this.error) {
              EmptyState({ icon: $r('sys.symbol.lightbulb'), title: t("没有发现新的长期记忆"), caption: t("相关内容可能已经保存过。你也可以手动写一条。") })
                .id('memory-empty')
            }
            ForEach(this.items, (item: string, index: number) => { this.draftCard(item, index) }, (_item: string, index: number) => String(index))
            if (this.items.length < 5) {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([$r('app.color.accent')])
                Text(t("手动写一条")).fontSize(14).fontColor($r('app.color.accent'))
              }.id('memory-add-draft').width('100%').height(48).justifyContent(FlexAlign.Center).borderRadius(Radius.lg)
              .border({ width: 1, color: $r('app.color.divider'), style: BorderStyle.Dashed })
              .enabled(!this.saving).opacity(this.saving ? 0.4 : 1)
              .onClick(() => { this.items = this.items.concat(['']); this.selected = this.selected.concat([true]); })
            }
            GroupCard() {
              SwitchRow({ title: t("用于所有对话"), subtitle: this.global ? t("保存后会作为所有对话的背景资料") : t("默认仅用于当前对话"), isOn: this.global,
                onChange: (value) => { if (!this.saving) { this.global = value; } } })
            }
            if (this.error) { Banner({ text: this.error }) }
          }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.xs, bottom: Space.lg })
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top).edgeEffect(EdgeEffect.Spring)
      }
      if (this.loading && this.error) { Banner({ text: this.error }).padding({ left: Space.page, right: Space.page }) }
      BottomBar({ sheet: true }) {
        Row({ space: Space.md }) {
          Button(this.loading ? t("取消提炼") : t("取消")).id('cancel-memory-draft').attributeModifier(Btn.tonal).layoutWeight(1)
            .enabled(!this.saving).onClick(() => this.close())
          Button(this.saving ? t("正在保存…") : this.chosen().length > 0 ? t('保存 {0} 条', [this.chosen().length]) : t("确认保存"))
            .id('save-memory-draft').attributeModifier(Btn.primary).layoutWeight(1)
            .enabled(this.ready()).onClick(() => this.save())
        }.width('100%')
      }
    }.width('100%').height('100%')
  }
}
