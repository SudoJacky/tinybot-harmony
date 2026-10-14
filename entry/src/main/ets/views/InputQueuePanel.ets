import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { PendingInput } from '../model/PendingInput';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Radius, Space } from '../common/Theme';

// Bottom-sheet content listing steering and follow-up inputs waiting to run.
@Component
export struct InputQueuePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  onContinue: () => void = () => {};
  onEdited: () => void = () => {};

  build() {
    Column({ space: Space.md }) {
      Row({ space: Space.sm }) {
        Text(this.thread.queuePaused ? t("队列已暂停，可继续或移除") : t("将在当前任务完成后按顺序执行")).fontFamily(this.appearance.fontFamily).id('queue-status')
          .fontSize(13).layoutWeight(1).fontColor($r('app.color.text_secondary'))
        if (!this.app.busy) {
          Button(t("继续执行")).fontFamily(this.appearance.fontFamily).id('resume-input-queue').attributeModifier(Btn.primarySmall)
            .enabled(this.app.canQueueInput && this.app.configured).onClick(() => this.onContinue())
        }
      }.width('100%')
      if (this.thread.pendingInputs.length === 0) {
        Text(t("没有待发送的内容")).fontFamily(this.appearance.fontFamily).fontSize(Font.small).fontColor($r('app.color.text_tertiary')).padding(Space.xl)
      }
      List({ space: Space.sm }) {
        ForEach(this.thread.pendingInputs, (input: PendingInput, index: number) => {
          ListItem() {
            Column({ space: Space.sm }) {
              Row({ space: Space.sm }) {
                Text(`${index + 1}`).fontFamily(this.appearance.fontFamily).fontSize(11).fontWeight(FontWeight.Medium).width(20).height(20)
                  .textAlign(TextAlign.Center).borderRadius(10).fontColor(this.appearance.onAccentContainer)
                  .backgroundColor(this.appearance.accentContainer)
                Text(input.mode === 'steer' ? t("追加指令") : t("排队任务")).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).layoutWeight(1)
                  .fontColor($r('app.color.text_secondary'))
                Button(t("撤回编辑")).fontFamily(this.appearance.fontFamily).id('edit-input-' + input.id).attributeModifier(Btn.textSmall)
                  .enabled(this.app.canQueueInput)
                  .onClick(async () => { await this.app.removePendingInput(input.id, true); this.onEdited(); })
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.trash')).fontSize(16).fontColor([$r('app.color.text_secondary')])
                }.fontFamily(this.appearance.fontFamily).id('remove-input-' + input.id).width(32).height(32).backgroundColor(Color.Transparent)
                .accessibilityText(t("移除")).enabled(this.app.canQueueInput)
                .onClick(() => this.app.removePendingInput(input.id))
              }.width('100%')
              Text(input.text).fontFamily(this.appearance.fontFamily).fontSize(Font.small).lineHeight(21).maxLines(4)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').fontColor($r('app.color.text_primary'))
            }.padding(Space.md).borderRadius(Radius.md).width('100%').backgroundColor($r('app.color.surface'))
          }
        }, (input: PendingInput) => input.id)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').padding({ left: Space.page, right: Space.page, bottom: Space.lg })
  }
}
