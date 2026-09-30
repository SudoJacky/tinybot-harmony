import { AgentStepViewModel, MessageViewModel, ToolExecutionViewModel } from '../viewmodel/ChatViewModel';

@Component
struct ToolActivity {
  @ObjectLink execution: ToolExecutionViewModel;
  @State private expanded: boolean = false;

  private title(): string {
    const name = this.execution.call.function.name;
    return name === 'list_files' ? '列出文件' : name === 'read_file' ? '读取文件' : name === 'write_file' ? '写入文件' : name;
  }

  private statusLabel(): string {
    switch (this.execution.status) {
      case 'pending': return '等待执行';
      case 'running': return '执行中';
      case 'complete': return '已完成';
      case 'failed': return '失败';
      case 'cancelled': return '已取消';
      default: return '已中断';
    }
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.title()).fontSize(13).fontWeight(FontWeight.Medium).layoutWeight(1)
          .fontColor($r('app.color.text_primary'))
        Text(this.statusLabel()).fontSize(12)
          .fontColor(this.execution.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
        Button(this.expanded ? '收起' : '详情').fontSize(12).height(28).padding({ left: 8, right: 8 })
          .backgroundColor(Color.Transparent).fontColor($r('app.color.accent'))
          .onClick(() => { this.expanded = !this.expanded; })
      }.width('100%')
      if (this.expanded) {
        Text(this.execution.call.function.arguments).fontSize(12).lineHeight(18)
          .fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.LocalDevice).width('100%')
        if (this.execution.output.length > 0) {
          Text(this.execution.output).fontSize(12).lineHeight(18).fontColor($r('app.color.text_primary'))
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }
      }
    }.padding(10).width('100%').borderRadius(10).backgroundColor($r('app.color.page_background'))
  }
}

@Component
struct AgentStepContent {
  @ObjectLink step: AgentStepViewModel;

  build() {
    Column({ space: 9 }) {
      if (this.step.content.length > 0) {
        Text(this.step.content).fontSize(16).lineHeight(25).fontColor($r('app.color.text_primary'))
          .copyOption(CopyOptions.LocalDevice).width('100%')
      }
      ForEach(this.step.tools, (execution: ToolExecutionViewModel) => {
        ToolActivity({ execution: execution })
      }, (execution: ToolExecutionViewModel) => execution.call.id)
    }.width('100%')
  }
}

@Component
export struct MessageBubble {
  @ObjectLink message: MessageViewModel;

  build() {
    Column({ space: 9 }) {
      Row({ space: 8 }) {
        if (this.message.role === 'assistant') {
          Image($r('app.media.tinybot')).width(22).height(22)
        }
        Text(this.message.role === 'user' ? '你' : 'Tinybot')
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
        if (this.message.modelRef) {
          Text(this.message.modelRef.modelId).fontSize(10).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
        }
        Blank()
        if (this.message.status === 'generating') {
          LoadingProgress().width(16).height(16).color($r('app.color.accent'))
          Text(`正在执行 · 第 ${Math.max(1, this.message.stepViews.length)} 步`).fontSize(12).fontColor($r('app.color.text_secondary'))
        } else if (this.message.status === 'stopped') {
          Text('已停止').fontSize(12).fontColor($r('app.color.text_secondary'))
        } else if (this.message.status === 'failed') {
          Text('未完成').fontSize(12).fontColor($r('app.color.danger'))
        }
      }.width('100%')
      if (this.message.stepViews.length > 0) {
        ForEach(this.message.stepViews, (step: AgentStepViewModel) => {
          AgentStepContent({ step: step })
        }, (_step: AgentStepViewModel, index: number) => index.toString())
      } else if (this.message.content.length > 0) {
        Text(this.message.content)
          .fontSize(16).lineHeight(25).fontColor($r('app.color.text_primary'))
          .copyOption(CopyOptions.LocalDevice).width('100%')
      } else if (this.message.status === 'generating') {
        Text('正在连接模型…').fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
      }
      if (this.message.error.length > 0) {
        Text(this.message.error).fontSize(13).lineHeight(20)
          .fontColor(this.message.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .padding(16).alignItems(HorizontalAlign.Start).width('100%').borderRadius(18)
    .backgroundColor(this.message.role === 'user' ? $r('app.color.user_bubble') : $r('app.color.surface'))
  }
}
