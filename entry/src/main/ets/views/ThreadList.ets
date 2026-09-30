import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';

@Component
struct ThreadRow {
  @ObjectLink thread: ThreadViewModel;
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  @State private editing: boolean = false;
  @State private name: string = '';

  @Builder
  actions() {
    Menu() {
      MenuItem({ content: '重命名' }).onClick(() => { this.name = this.thread.title; this.editing = true; })
      MenuItem({ content: this.thread.pinned ? '取消置顶' : '置顶' }).onClick(() => this.app.pinThread(this.thread.id))
      MenuItem({ content: this.thread.archived ? '恢复对话' : '归档' }).onClick(() => this.app.archiveThread(this.thread.id))
      MenuItem({ content: '删除' }).onClick(() => {
        this.getUIContext().showAlertDialog({
          title: '删除这段对话？', message: this.thread.title + '\n会话工作区中的文件会保留。',
          primaryButton: { value: '取消', action: () => {} },
          secondaryButton: { value: '删除', action: () => { this.app.deleteThread(this.thread.id); } }
        });
      })
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 7 }) {
            Text((this.thread.pinned ? '置顶 · ' : '') + this.thread.title).fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            Text(new Date(this.thread.updatedAt).toLocaleString() + (this.thread.draft.length > 0 ? ' · 有草稿' : ''))
              .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        .backgroundColor(Color.Transparent).padding(16).layoutWeight(1)
        .enabled(!this.app.busy && this.app.saveError.length === 0)
        .onClick(async () => { if (await this.app.selectThread(this.thread.id)) { this.onSelected(); } })
        Button('···').fontSize(22).height(44).width(44).margin({ right: 8 })
          .accessibilityText('对话管理').backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
          .enabled(!this.app.busy && this.app.saveError.length === 0).bindMenu(this.actions)
      }.width('100%')
      if (this.editing) {
        Column({ space: 8 }) {
          TextInput({ text: this.name, placeholder: '对话名称' }).maxLength(80)
            .onChange((value: string) => { this.name = value; })
          Row({ space: 8 }) {
            Button('取消').onClick(() => { this.editing = false; })
            Button('保存名称').enabled(!this.app.busy && this.app.saveError.length === 0)
              .onClick(async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } })
          }
        }.padding({ left: 16, right: 16, bottom: 16 })
      }
    }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(18)
  }
}

@Component
export struct ThreadList {
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  @State private query: string = '';
  @State private archived: boolean = false;
  @State private visibleCount: number = 40;

  build() {
    Column({ space: 16 }) {
      Row() {
        Text(`${this.app.filteredThreads(this.query, this.archived).length} 段${this.archived ? '已归档' : ''}对话`)
          .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Button('新对话').id('history-new-chat').fontSize(14).height(40)
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
          .enabled(!this.app.busy && this.app.saveError.length === 0)
          .onClick(async () => { if (await this.app.newThread()) { this.onSelected(); } })
      }.width('100%')
      Search({ value: this.query, placeholder: '搜索名称或消息正文' }).id('search-threads')
        .onChange((value: string) => { this.query = value; this.visibleCount = 40; })
      Row({ space: 12 }) {
        Button('当前对话').id('active-threads').fontSize(13)
          .fontColor(this.archived ? $r('app.color.text_secondary') : $r('app.color.accent'))
          .onClick(() => { this.archived = false; this.visibleCount = 40; })
        Button('已归档').id('archived-threads').fontSize(13)
          .fontColor(this.archived ? $r('app.color.accent') : $r('app.color.text_secondary'))
          .onClick(() => { this.archived = true; this.visibleCount = 40; })
      }.width('100%')
      if (this.app.filteredThreads(this.query, this.archived).length === 0) {
        Text(this.query.trim().length > 0 ? '没有匹配的对话' : this.archived ? '没有归档的对话' : '还没有对话')
          .fontSize(18).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      } else {
        List({ space: 12 }) {
          ForEach(this.app.filteredThreads(this.query, this.archived).slice(0, this.visibleCount), (thread: ThreadViewModel) => {
            ListItem() { ThreadRow({ thread: thread, app: this.app, onSelected: this.onSelected }) }
          }, (thread: ThreadViewModel) => thread.id)
          if (this.app.filteredThreads(this.query, this.archived).length > this.visibleCount) {
            ListItem() {
              Button('加载更多对话').id('load-more-threads').width('100%')
                .onClick(() => { this.visibleCount += 40; })
            }
          }
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
