import { SymbolGlyphModifier } from '@kit.ArkUI';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Radius, Space, dayGroup, shortTime } from '../common/Theme';
import { Banner, IconButton } from '../common/Widgets';

class ThreadSection {
  title: string;
  threads: ThreadViewModel[] = [];

  constructor(title: string) {
    this.title = title;
  }
}

@Component
struct ThreadRow {
  @ObjectLink thread: ThreadViewModel;
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  @State private editing: boolean = false;
  @State private name: string = '';

  private get locked(): boolean {
    return this.app.busy || this.app.saveError.length > 0;
  }

  private get active(): boolean {
    return this.app.active.id === this.thread.id;
  }

  @Builder
  actions() {
    Menu() {
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')), content: '重命名' })
        .onClick(() => { this.name = this.thread.title; this.editing = true; })
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.pin')),
        content: this.thread.pinned ? '取消置顶' : '置顶' })
        .onClick(() => this.app.pinThread(this.thread.id))
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.archivebox')),
        content: this.thread.archived ? '恢复对话' : '归档' })
        .onClick(() => this.app.archiveThread(this.thread.id))
      MenuItem({ symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([$r('app.color.danger')]),
        content: '删除' }).contentFontColor($r('app.color.danger'))
        .onClick(() => {
          this.getUIContext().showAlertDialog({
            title: '删除这段对话？', message: this.thread.title + '\n会话工作区中的文件会保留。',
            primaryButton: { value: '取消', action: () => {} },
            secondaryButton: { value: '删除', fontColor: $r('app.color.danger'),
              action: () => { this.app.deleteThread(this.thread.id); } }
          });
        })
    }
  }

  @Builder
  renameEditor() {
    Row({ space: 4 }) {
      TextInput({ text: this.name, placeholder: '对话名称' }).maxLength(80).layoutWeight(1).height(40)
        .fontSize(15).backgroundColor($r('app.color.surface')).defaultFocus(true)
        .onChange((value: string) => { this.name = value; })
        .onSubmit(async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.xmark'), label: '取消', diameter: 36, iconSize: 18,
        tint: $r('app.color.text_secondary'), onTap: () => { this.editing = false; } })
      IconButton({ icon: $r('sys.symbol.checkmark'), label: '保存名称', diameter: 36, iconSize: 18,
        tint: $r('app.color.accent'), disabled: this.locked,
        onTap: async () => { if (await this.app.renameThread(this.thread.id, this.name)) { this.editing = false; } } })
    }.width('100%').padding({ left: Space.sm, right: 4, top: 6, bottom: 6 })
  }

  build() {
    Column() {
      if (this.editing) {
        this.renameEditor()
      } else {
        Row({ space: Space.sm }) {
          Column({ space: 4 }) {
            Row({ space: 4 }) {
              if (this.thread.pinned) {
                SymbolGlyph($r('sys.symbol.pin_fill')).fontSize(13).fontColor([$r('app.color.accent')])
              }
              Text(this.thread.title).fontSize(15).maxLines(1).layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.active ? $r('app.color.on_accent_container') : $r('app.color.text_primary'))
            }.width('100%')
            Row({ space: 6 }) {
              Text(shortTime(this.thread.updatedAt)).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
              if (this.thread.draft.length > 0) {
                Text('草稿').fontSize(11).fontColor($r('app.color.danger'))
              }
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          }.width(32).height(32).backgroundColor(Color.Transparent).accessibilityText('对话管理')
          .enabled(!this.locked).bindMenu(this.actions)
        }
        .width('100%').padding({ left: Space.md, right: 4, top: 10, bottom: 10 })
        .onClick(async () => {
          if (this.locked) { return; }
          if (await this.app.selectThread(this.thread.id)) { this.onSelected(); }
        })
        .bindContextMenu(this.actions, ResponseType.LongPress)
      }
    }
    .width('100%').borderRadius(Radius.md)
    .backgroundColor(this.active ? $r('app.color.accent_container') : Color.Transparent)
    .opacity(this.locked && !this.active ? 0.6 : 1)
  }
}

// Conversation drawer: search, active/archived switch, date-grouped rows and settings entry.
@Component
export struct ThreadList {
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  onSettings: () => void = () => {};
  @State private query: string = '';
  @State private archived: boolean = false;
  @State private visibleCount: number = 40;

  private sections(threads: ThreadViewModel[]): ThreadSection[] {
    const result: ThreadSection[] = [];
    for (const thread of threads) {
      const title = thread.pinned && !this.archived ? '置顶' : dayGroup(thread.updatedAt);
      let section = result.find((item: ThreadSection) => item.title === title);
      if (!section) {
        section = new ThreadSection(title);
        result.push(section);
      }
      section.threads.push(thread);
    }
    return result;
  }

  @Builder
  sectionHeader(title: string) {
    Text(title).fontSize(Font.caption).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_tertiary'))
      .width('100%').padding({ left: Space.md, top: Space.md, bottom: 4 })
      .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  tab(label: string, compId: string, archived: boolean) {
    Text(label).id(compId).fontSize(13).layoutWeight(1).height(32).textAlign(TextAlign.Center).borderRadius(16)
      .fontWeight(this.archived === archived ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.archived === archived ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
      .backgroundColor(this.archived === archived ? $r('app.color.surface') : Color.Transparent)
      .onClick(() => { this.archived = archived; this.visibleCount = 40; })
  }

  build() {
    Column({ space: Space.md }) {
      Row({ space: Space.sm }) {
        Image($r('app.media.tinybot')).width(28).height(28)
        Text('Tinybot').fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1).fontColor($r('app.color.text_primary'))
      }.width('100%').height(48).padding({ left: 4 })
      Button() {
        Row({ space: Space.sm }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([$r('app.color.on_accent_container')])
          Text('新对话').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.on_accent_container'))
        }
      }.id('history-new-chat').attributeModifier(Btn.tonal).width('100%')
      .enabled(!this.app.busy && this.app.saveError.length === 0)
      .onClick(async () => { if (await this.app.newThread()) { this.onSelected(); } })
      Search({ value: this.query, placeholder: '搜索对话' }).id('search-threads').height(40)
        .backgroundColor($r('app.color.surface_variant')).placeholderColor($r('app.color.text_tertiary'))
        .onChange((value: string) => { this.query = value; this.visibleCount = 40; })
      Row({ space: 2 }) {
        this.tab('对话', 'active-threads', false)
        this.tab('已归档', 'archived-threads', true)
      }.width('100%').padding(3).borderRadius(19).backgroundColor($r('app.color.surface_variant'))
      if (this.app.filteredThreads(this.query, this.archived).length === 0) {
        Column({ space: Space.sm }) {
          SymbolGlyph(this.query.trim().length > 0 ? $r('sys.symbol.magnifyingglass') : $r('sys.symbol.ellipsis_message'))
            .fontSize(32).fontColor([$r('app.color.text_tertiary')])
          Text(this.query.trim().length > 0 ? '没有匹配的对话' : this.archived ? '没有归档的对话' : '还没有对话')
            .fontSize(Font.small).fontColor($r('app.color.text_secondary'))
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          ForEach(this.sections(this.app.filteredThreads(this.query, this.archived).slice(0, this.visibleCount)),
            (section: ThreadSection) => {
              ListItemGroup({ header: this.sectionHeader(section.title), space: 2 }) {
                ForEach(section.threads, (thread: ThreadViewModel) => {
                  ListItem() { ThreadRow({ thread: thread, app: this.app, onSelected: this.onSelected }) }
                }, (thread: ThreadViewModel) => thread.id)
              }
            }, (section: ThreadSection) => section.title + ':' + section.threads.map((t) => t.id).join(','))
          if (this.app.filteredThreads(this.query, this.archived).length > this.visibleCount) {
            ListItem() {
              Button('加载更多对话').id('load-more-threads').attributeModifier(Btn.textSmall)
                .onClick(() => { this.visibleCount += 40; })
            }.width('100%')
          }
        }.layoutWeight(1).width('100%').sticky(StickyStyle.Header).scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      if (this.app.saveError.length > 0) {
        Banner({ text: this.app.saveError, actionLabel: '重试', actionEnabled: !this.app.busy,
          onAction: () => { this.app.retrySave(); } })
      } else if (this.app.error.length > 0) {
        Banner({ text: this.app.error })
      }
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      Row({ space: Space.md }) {
        SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('app.color.text_secondary')])
        Text('设置').fontSize(15).layoutWeight(1).fontColor($r('app.color.text_primary'))
        Text(`${this.app.providerProfiles.length} 个服务`).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
      }
      .id('open-settings').width('100%').height(48).padding({ left: Space.md, right: Space.md }).borderRadius(Radius.md)
      .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
      .onClick(() => this.onSettings())
    }
    .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
    .height('100%').width('100%').backgroundColor($r('app.color.page_background'))
  }
}
