import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';

@Component
struct ThreadRow {
  @ObjectLink thread: ThreadViewModel;
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 7 }) {
          Text(this.thread.title).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(new Date(this.thread.updatedAt).toLocaleString()).fontSize(12)
            .fontColor($r('app.color.text_secondary')).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      .backgroundColor(Color.Transparent).padding(16).layoutWeight(1).enabled(!this.app.busy && this.app.saveError.length === 0)
      .onClick(async () => { if (await this.app.selectThread(this.thread)) { this.onSelected(); } })
      Button('删除').fontSize(12).height(40).margin({ right: 8 })
        .backgroundColor(Color.Transparent).fontColor($r('app.color.danger'))
        .enabled(!this.app.busy && this.app.saveError.length === 0)
        .onClick(() => {
          this.getUIContext().showAlertDialog({
            title: '删除这段对话？', message: this.thread.title + '\n会话工作区中的文件会保留。',
            primaryButton: { value: '取消', action: () => {} },
            secondaryButton: { value: '删除', action: () => { this.app.deleteThread(this.thread); } }
          });
        })
    }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(18)
  }
}

@Component
export struct ThreadList {
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};

  build() {
    Column({ space: 16 }) {
      Row() {
        Text(`${this.app.threads.length} 段对话 · 仅保存在本机`).fontSize(13)
          .fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Button('新对话').id('history-new-chat').fontSize(14).height(40)
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
          .enabled(!this.app.busy && this.app.saveError.length === 0)
          .onClick(async () => { if (await this.app.newThread()) { this.onSelected(); } })
      }.width('100%')
      if (this.app.threads.length === 0) {
        Column({ space: 12 }) {
          Text('还没有对话').fontSize(22).fontColor($r('app.color.text_primary'))
          Text('从一个问题开始，Tinybot 会为你保存。').fontSize(14).fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
      } else {
        List({ space: 12 }) {
          ForEach(this.app.threads, (thread: ThreadViewModel) => {
            ListItem() { ThreadRow({ thread: thread, app: this.app, onSelected: this.onSelected }) }
          }, (thread: ThreadViewModel) => thread.id)
        }.layoutWeight(1).width('100%')
      }
      if (this.app.error.length > 0) {
        Text(this.app.error).fontSize(13).fontColor($r('app.color.danger'))
      }
      if (this.app.saveError.length > 0) {
        Text(this.app.saveError).fontSize(13).fontColor($r('app.color.danger'))
        Button('重试保存').onClick(() => this.app.retrySave()).enabled(!this.app.busy)
      }
    }.padding(20).height('100%').width('100%')
  }
}
