import { t } from '../model/I18n';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Radius, Space, shortTime } from '../common/Theme';
import { EmptyState, IconBadge, Tag } from '../common/Widgets';

const INDENT: number = 20;

// Conversation family tree: only threads that have a parent or children are listed, roots first, depth-first.
@Component
export struct BranchesPanel {
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  private parent(thread: ThreadViewModel): ThreadViewModel | undefined {
    return thread.parentThreadId ? this.app.threads.find((item) => item.id === thread.parentThreadId) : undefined;
  }
  private depth(thread: ThreadViewModel): number {
    let current = thread; let depth = 0; const seen = new Set<string>();
    while (current.parentThreadId && !seen.has(current.id) && depth < 12) {
      seen.add(current.id); const parent = this.parent(current);
      if (!parent) { break; } depth++; current = parent;
    }
    return depth;
  }
  private ordered(): ThreadViewModel[] {
    const pending = this.app.threads.filter((item) => !item.parentThreadId || !this.app.threads.some((parent) => parent.id === item.parentThreadId));
    const result: ThreadViewModel[] = []; const seen = new Set<string>();
    while (pending.length) { const item = pending.shift(); if (!item || seen.has(item.id)) { continue; } seen.add(item.id); result.push(item); pending.unshift(...this.app.threads.filter((child) => child.parentThreadId === item.id)); }
    return result.concat(this.app.threads.filter((item) => !seen.has(item.id)));
  }
  private branched(): ThreadViewModel[] {
    return this.ordered().filter((thread) => !!this.parent(thread) || this.app.threads.some((child) => child.parentThreadId === thread.id));
  }
  private async open(thread: ThreadViewModel): Promise<void> {
    if (await this.app.selectThread(thread.id)) { this.onSelected(); }
  }

  @Builder
  row(thread: ThreadViewModel) {
    Row() {
      if (this.depth(thread) > 0) {
        Column().width((this.depth(thread) - 1) * INDENT + 8)
        Column().width(12).height(30).margin({ right: 4, bottom: 30 })
          .border({ width: { left: 1.5, bottom: 1.5 }, color: $r('app.color.divider') }).borderRadius({ bottomLeft: 8 })
      }
      Row({ space: Space.md }) {
        IconBadge({ icon: thread.parentThreadId ? $r('sys.symbol.split') : $r('sys.symbol.ellipsis_message'),
          tint: thread.id === this.app.active.id ? $r('app.color.accent') : $r('app.color.text_secondary'),
          fill: thread.id === this.app.active.id ? $r('app.color.accent_container') : $r('app.color.surface_variant') })
        Column({ space: 4 }) {
          Text(thread.displayTitle).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontWeight(thread.id === this.app.active.id ? FontWeight.Medium : FontWeight.Normal)
            .fontColor($r('app.color.text_primary'))
          Row({ space: 6 }) {
            if (thread.id === this.app.active.id) { Tag({ text: t("当前"), strong: true }) }
            if (thread.archived) { Tag({ text: t("已归档") }) }
            Text(thread.messages.length + t(" 条消息 · ") + shortTime(thread.updatedAt)).fontSize(Font.caption).maxLines(1)
              .fontColor($r('app.color.text_tertiary'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (thread.parentThreadId && thread.parentMessageId && this.parent(thread)) {
          Button(t("起点")).attributeModifier(Btn.textSmall).padding({ left: 10, right: 10 })
            .accessibilityText(t("回到分支起点消息"))
            .onClick(async () => {
              if (await this.app.openMessage(thread.parentThreadId || '', thread.parentMessageId || '')) { this.onSelected(); }
            })
        }
      }
      .layoutWeight(1).padding({ left: Space.md, right: 4, top: 10, bottom: 10 }).borderRadius(Radius.md)
      .backgroundColor($r('app.color.surface'))
      .border({ width: thread.id === this.app.active.id ? 1 : 0, color: $r('app.color.accent_container') })
      .stateStyles({ pressed: { .opacity(0.7) }, normal: { .opacity(1) } })
      .onClick(() => this.open(thread))
    }.width('100%').alignItems(VerticalAlign.Center)
  }

  build() {
    List({ space: Space.sm }) {
      if (this.branched().length === 0) {
        ListItem() {
          EmptyState({ icon: $r('sys.symbol.split'), title: t("还没有分支"),
            caption: t("长按任意消息，选择“从这里创建分支”，即可在不影响原对话的情况下尝试另一种方向。") })
        }
      }
      ForEach(this.branched(), (thread: ThreadViewModel, index: number) => {
        ListItem() { this.row(thread) }
          .margin({ top: index > 0 && !thread.parentThreadId ? Space.lg : 0 })
      }, (thread: ThreadViewModel) => thread.id + ':' + thread.title + ':' + thread.updatedAt + ':' + (thread.id === this.app.active.id))
    }.padding({ left: Space.page, right: Space.page, top: Space.sm }).width('100%').height('100%')
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).contentEndOffset(Space.xl)
  }
}
