import { AgentStepViewModel, MessageViewModel, ToolExecutionViewModel } from '../viewmodel/ChatViewModel';
import { Font, Radius, Space } from '../common/Theme';

@Component
struct ToolActivity {
  @ObjectLink execution: ToolExecutionViewModel;
  @State private expanded: boolean = false;

  private title(): string {
    const name = this.execution.call.function.name;
    if (name === 'read_web') { return '读取网页'; }
    if (name === 'read_skill') { return '读取 Skill'; }
    return name === 'list_files' ? '列出文件' : name === 'read_file' ? '读取文件' : name === 'write_file' ? '写入文件' : name;
  }

  private icon(): Resource {
    const name = this.execution.call.function.name;
    if (name === 'read_web') { return $r('sys.symbol.magnifyingglass'); }
    if (name === 'read_skill') { return $r('sys.symbol.wand_and_stars'); }
    if (name === 'list_files') { return $r('sys.symbol.rectangle_stack'); }
    if (name === 'write_file') { return $r('sys.symbol.square_and_pencil'); }
    return $r('sys.symbol.doc_text');
  }

  private statusLabel(): string {
    switch (this.execution.status) {
      case 'pending': return '等待中';
      case 'running': return '执行中';
      case 'complete': return '完成';
      case 'failed': return '失败';
      case 'cancelled': return '已取消';
      default: return '已中断';
    }
  }

  build() {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        SymbolGlyph(this.icon()).fontSize(15).fontColor([$r('app.color.text_secondary')])
        Text(this.title()).fontSize(13).fontWeight(FontWeight.Medium).maxLines(1).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        if (this.execution.status === 'running') {
          LoadingProgress().width(14).height(14).color($r('app.color.accent'))
        }
        Text(this.statusLabel()).fontSize(Font.caption)
          .fontColor(this.execution.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(13).fontColor([$r('app.color.text_tertiary')])
      }.width('100%').height(24)
      if (this.expanded) {
        Text('参数').fontSize(11).fontColor($r('app.color.text_tertiary')).width('100%')
        Scroll() {
          Text(this.execution.call.function.arguments).fontSize(12).lineHeight(18).width('100%')
            .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_secondary'))
        }.constraintSize({ maxHeight: 160 }).width('100%').align(Alignment.TopStart)
        if (this.execution.output.length > 0) {
          Text('结果').fontSize(11).fontColor($r('app.color.text_tertiary')).width('100%')
          Scroll() {
            Text(this.execution.output).fontSize(12).lineHeight(18).width('100%')
              .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
          }.constraintSize({ maxHeight: 240 }).width('100%').align(Alignment.TopStart)
        }
      }
    }
    .padding({ left: Space.md, right: Space.md, top: 8, bottom: 8 }).width('100%').borderRadius(Radius.sm)
    .backgroundColor($r('app.color.surface_variant'))
    .accessibilityText(this.title() + ' ' + this.statusLabel())
    .onClick(() => { this.expanded = !this.expanded; })
  }
}

@Component
struct AgentStepContent {
  @ObjectLink step: AgentStepViewModel;

  build() {
    Column({ space: Space.sm }) {
      if (this.step.steering) {
        Column({ space: 4 }) {
          Text('追加指令').fontSize(11).fontColor($r('app.color.text_secondary'))
          Text(this.step.steering.text).fontSize(15).lineHeight(22)
            .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start).padding({ left: 14, right: 14, top: 8, bottom: 10 })
        .constraintSize({ maxWidth: '85%' }).borderRadius(Radius.md).backgroundColor($r('app.color.user_bubble'))
        .alignSelf(ItemAlign.End)
      }
      if (this.step.content.length > 0) {
        Text(this.step.content).fontSize(Font.body).lineHeight(26).fontColor($r('app.color.text_primary'))
          .copyOption(CopyOptions.LocalDevice).width('100%')
      }
      ForEach(this.step.tools, (execution: ToolExecutionViewModel) => {
        ToolActivity({ execution: execution })
      }, (execution: ToolExecutionViewModel) => execution.call.id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct MessageBubble {
  @ObjectLink message: MessageViewModel;

  @Builder
  userMessage() {
    Column({ space: 4 }) {
      Text(this.message.content).fontSize(Font.body).lineHeight(24)
        .fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
        .backgroundColor($r('app.color.user_bubble'))
      if (this.message.error.length > 0) {
        Text(this.message.error).fontSize(Font.caption).fontColor($r('app.color.danger'))
      }
    }.width('100%').alignItems(HorizontalAlign.End).padding({ left: 48 })
  }

  @Builder
  assistantMessage() {
    Column({ space: 10 }) {
      Row({ space: Space.sm }) {
        Image($r('app.media.tinybot')).width(22).height(22)
        Text('Tinybot').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        if (this.message.modelRef) {
          Text(this.message.modelRef.modelId).fontSize(11).maxLines(1).layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
        } else {
          Blank()
        }
        if (this.message.status === 'generating') {
          LoadingProgress().width(16).height(16).color($r('app.color.accent'))
          Text(`第 ${Math.max(1, this.message.stepViews.length)} 步`).fontSize(Font.caption)
            .fontColor($r('app.color.text_secondary'))
        } else if (this.message.status === 'stopped') {
          Text('已停止').fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
        } else if (this.message.status === 'failed') {
          Text('未完成').fontSize(Font.caption).fontColor($r('app.color.danger'))
        }
      }.width('100%')
      if (this.message.stepViews.length > 0) {
        ForEach(this.message.stepViews, (step: AgentStepViewModel) => {
          AgentStepContent({ step: step })
        }, (_step: AgentStepViewModel, index: number) => index.toString())
      } else if (this.message.content.length > 0) {
        Text(this.message.content).fontSize(Font.body).lineHeight(26).fontColor($r('app.color.text_primary'))
          .copyOption(CopyOptions.LocalDevice).width('100%')
      } else if (this.message.status === 'generating') {
        Text('正在思考…').fontSize(15).fontColor($r('app.color.text_tertiary')).width('100%')
      }
      if (this.message.error.length > 0) {
        Text(this.message.error).fontSize(13).lineHeight(20).width('100%')
          .padding({ left: Space.md, right: Space.md, top: 8, bottom: 8 }).borderRadius(Radius.sm)
          .fontColor(this.message.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
          .backgroundColor(this.message.status === 'failed' ? $r('app.color.danger_container') : $r('app.color.surface_variant'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.message.role === 'user') {
        this.userMessage()
      } else {
        this.assistantMessage()
      }
    }.width('100%')
  }
}
