import { t } from '../model/I18n';
import { LengthMetrics } from '@kit.ArkUI';
import { AgentStep, ToolExecution } from '../model/Agent';
import { TeamArtifact, TeamAttempt, TeamMember, TeamRun, TeamTaskRecord, teamStatus } from '../model/Team';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Font, Motion, Radius, Space, compactNumber } from '../common/Theme';
import { MarkdownView } from './MarkdownView';
import { TeamMemberAvatar } from './TeamMemberAvatar';

interface TeamCardInput { run: TeamRun; }
interface TeamStatusInput { status: string; }
interface TeamAvatarInput { run: TeamRun; member: TeamMember; size: number; ring: boolean; }
interface TeamToolInput { tool: ToolExecution; }
interface TeamAttemptInput { record: TeamTaskRecord; attempt: TeamAttempt; index: number; }
interface TeamTaskInput { run: TeamRun; record: TeamTaskRecord; }

function LOG_TITLES(): Record<string, string> { return {
  'team_complete_task': t("提交交接"), 'team_list_messages': t("查看团队交接"), 'team_read_message': t("读取交接"),
  'read_web': t("读取网页"), 'list_files': t("列出文件"), 'read_file': t("读取文件"), 'read_file_lines': t("读取文件片段"),
  'search_file_content': t("搜索文件内容"), 'write_file': t("写入文件"), 'edit_file': t("编辑文件"), 'read_skill': t("读取 Skill")
}; }

function toneForeground(status: string): ResourceColor {
  if (status === 'failed') { return $r('app.color.danger'); }
  if (['paused', 'interrupted', 'cancelled'].includes(status)) { return $r('app.color.warning'); }
  if (['running', 'completed', 'succeeded'].includes(status)) { return $r('app.color.on_accent_container'); }
  return $r('app.color.text_secondary');
}

function toneBackground(status: string): ResourceColor {
  if (status === 'failed') { return $r('app.color.danger_container'); }
  if (['paused', 'interrupted', 'cancelled'].includes(status)) { return $r('app.color.warning_container'); }
  if (['running', 'completed', 'succeeded'].includes(status)) { return $r('app.color.accent_container'); }
  return $r('app.color.surface_variant');
}

function clock(time: number): string {
  const date = new Date(time);
  return date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
}

function duration(ms: number): string {
  const seconds = Math.max(1, Math.round(ms / 1000));
  return seconds < 60 ? t('{0} 秒', [seconds]) : t('{0} 分 {1} 秒', [Math.floor(seconds / 60), seconds % 60]);
}

function baseName(path: string): string {
  const parts = path.split('/');
  return parts[parts.length - 1] || path;
}

@Component
struct ChatTeamRun {
  @ObjectLink app: ChatViewModel;
  @Prop runId: string = '';
  onFiles: () => void = () => {};
  @State private expanded: boolean = false;
  @State private expandedTasks: string[] = [];
  @State private expandedLogs: string[] = [];
  @State private expandedBriefs: string[] = [];

  aboutToAppear(): void {
    // A team working right now opens by default so its progress is visible without a tap.
    this.expanded = this.current()?.status === 'running';
  }

  private current(): TeamRun | undefined { return this.app.teams.find((run) => run.id === this.runId); }
  private memberName(run: TeamRun, id: string): string { return run.members.find((member) => member.id === id)?.name || id; }
  private memberBusy(run: TeamRun, id: string): boolean {
    return run.tasks.some((record) => record.task.memberId === id && record.status === 'running');
  }
  private doneCount(run: TeamRun): number { return run.tasks.filter((record) => record.status === 'succeeded').length; }
  private toggleList(list: string[], id: string): string[] {
    return list.includes(id) ? list.filter((item) => item !== id) : list.concat([id]);
  }
  private animate(change: () => void): void {
    this.getUIContext().animateTo({ duration: Motion.medium, curve: Motion.standard }, change);
  }
  private usage(run: TeamRun): string {
    let input = 0; let output = 0; let missing = 0;
    let steps = run.planning.steps.slice();
    for (const record of run.tasks) { for (const attempt of record.attempts) { steps = steps.concat(attempt.turn.steps); } }
    for (const step of steps) {
      if (step.usage?.tokens) { input += step.usage.tokens.input; output += step.usage.tokens.output; } else { missing++; }
    }
    return t("员工用量 · 输入 ") + compactNumber(input) + t(" · 输出 ") + compactNumber(output) +
      (missing ? ' · ' + missing + t(" 次未报告") : '');
  }
  private toolCount(attempt: TeamAttempt): number {
    return attempt.turn.steps.reduce((sum: number, step: AgentStep) => sum + step.tools.length, 0);
  }

  @Builder
  avatar(input: TeamAvatarInput) {
    TeamMemberAvatar({ memberId: input.member.id, diameter: input.size, ring: input.ring, busy: this.memberBusy(input.run, input.member.id),
      label: input.member.name + (this.memberBusy(input.run, input.member.id) ? t("，工作中") : '') })
  }

  @Builder
  // Object-literal arguments are passed by reference in ArkUI builders. A string parameter
  // captures the initial "running" value and leaves this badge stale after task completion.
  statusPill(input: TeamStatusInput) {
    Row({ space: 4 }) {
      if (input.status === 'running') {
        LoadingProgress().width(12).height(12).color(toneForeground(input.status))
      }
      Text(teamStatus(input.status)).fontSize(11).fontWeight(FontWeight.Medium).fontColor(toneForeground(input.status))
    }.id('team-status-' + this.runId).height(22).padding({ left: 8, right: 8 }).borderRadius(11)
    .backgroundColor(toneBackground(input.status))
  }

  @Builder
  taskGlyph(input: TeamStatusInput) {
    Stack() {
      if (input.status === 'running') {
        LoadingProgress().width(18).height(18).color($r('app.color.accent'))
      } else if (input.status === 'succeeded') {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(18).fontColor([$r('app.color.accent')])
      } else if (input.status === 'failed') {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(18).fontColor([$r('app.color.danger')])
      } else if (input.status === 'interrupted' || input.status === 'cancelled') {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(18).fontColor([$r('app.color.warning')])
      } else {
        SymbolGlyph($r('sys.symbol.circle')).fontSize(18).fontColor([$r('app.color.text_tertiary')])
      }
    }.width(20).height(20)
  }

  @Builder
  label(text: string) {
    Text(text).fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_tertiary'))
  }

  @Builder
  toolLog(input: TeamToolInput) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(LOG_TITLES()[input.tool.call.function.name] || input.tool.call.function.name).fontSize(12).fontWeight(FontWeight.Medium)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        if (input.tool.status === 'running') {
          LoadingProgress().width(12).height(12).color($r('app.color.accent'))
        } else if (input.tool.status === 'complete') {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(12).fontColor([$r('app.color.accent')])
        } else {
          Text(input.tool.status === 'failed' ? t("失败") : t("已中断")).fontSize(11)
            .fontColor(input.tool.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        }
      }.width('100%')
      Text(input.tool.call.function.arguments).fontSize(11).lineHeight(16).fontFamily('monospace').maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_secondary'))
      if (input.tool.output) {
        Text(input.tool.output).fontSize(11).lineHeight(16).maxLines(6).textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_secondary'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.surface_variant')).borderRadius(Radius.sm)
  }

  @Builder
  attemptView(input: TeamAttemptInput) {
    Column({ space: Space.sm }) {
      Text((input.record.attempts.length > 1 ? t("第 ") + (input.index + 1) + t(" 次 · ") : '') + teamStatus(input.attempt.status) + ' · ' + clock(input.attempt.startedAt) +
        (input.attempt.finishedAt ? t(" · 用时 ") + duration(input.attempt.finishedAt - input.attempt.startedAt) : ''))
        .fontSize(11).fontColor($r('app.color.text_tertiary'))
      if (input.attempt.error) {
        Text(input.attempt.error).fontSize(13).lineHeight(19).width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(Radius.sm).fontColor($r('app.color.danger')).backgroundColor($r('app.color.danger_container'))
          .copyOption(CopyOptions.LocalDevice)
      }
      if (input.attempt.handoff) {
        this.label(t("交接"))
        Column() {
          MarkdownView({ content: input.attempt.handoff.summary, fontSize: 14 })
        }.width('100%').padding({ left: Space.md, right: 4 })
        .border({ width: { left: 2 }, color: $r('app.color.accent_outline') })
        if (input.attempt.handoff.unresolved.length) {
          this.label(t("未解决"))
          ForEach(input.attempt.handoff.unresolved, (item: string) => {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(14).fontColor([$r('app.color.warning')])
                .margin({ top: 2 })
              Text(item).fontSize(13).lineHeight(19).layoutWeight(1).fontColor($r('app.color.text_primary'))
                .copyOption(CopyOptions.LocalDevice)
            }.width('100%').alignItems(VerticalAlign.Top)
          }, (item: string, i: number) => i + item)
        }
        if (input.attempt.handoff.artifacts.length) {
          this.label(t("产物"))
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
            ForEach(input.attempt.handoff.artifacts, (artifact: TeamArtifact) => {
              Row({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.doc_text')).fontSize(14).fontColor([$r('app.color.accent')])
                Text(baseName(artifact.path)).fontSize(12).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 200 }).fontColor($r('app.color.text_primary'))
              }.height(30).padding({ left: 8, right: 10 }).borderRadius(15)
              .backgroundColor($r('app.color.surface_variant')).clickEffect(Motion.press)
              .accessibilityText(t("在工作区查看 ") + artifact.path)
              .enabled(!this.app.busy).onClick(() => this.onFiles())
            }, (artifact: TeamArtifact) => artifact.path)
          }.width('100%')
        }
      } else if (input.attempt.turn.content) {
        MarkdownView({ content: input.attempt.turn.content, fontSize: 14 })
      } else if (input.attempt.status === 'running') {
        Text(t("正在工作，完成后会提交交接…")).fontSize(13).fontColor($r('app.color.text_tertiary'))
      }
      if (this.toolCount(input.attempt) > 0) {
        Row({ space: 4 }) {
          Text(t("执行记录 · ") + this.toolCount(input.attempt) + t(" 次工具调用")).fontSize(12).fontColor($r('app.color.text_secondary'))
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.text_tertiary')])
            .rotate({ angle: this.expandedLogs.includes(input.attempt.id) ? 180 : 0 })
        }.id('team-log-' + input.attempt.id).height(32)
        .onClick(() => this.animate(() => { this.expandedLogs = this.toggleList(this.expandedLogs, input.attempt.id); }))
        if (this.expandedLogs.includes(input.attempt.id)) {
          Column({ space: 6 }) {
            ForEach(input.attempt.turn.steps.map((_step, index: number) => index), (stepIndex: number) => {
              ForEach(input.attempt.turn.steps[stepIndex].tools.map((tool) => tool.call.id), (callId: string) => {
                this.toolLog({ tool: input.attempt.turn.steps[stepIndex].tools.find((tool) => tool.call.id === callId) as ToolExecution })
              }, (callId: string) => callId)
            }, (stepIndex: number) => stepIndex.toString())
          }.width('100%').transition(TransitionEffect.OPACITY)
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  taskRow(input: TeamTaskInput) {
    Column({ space: Space.sm }) {
      Row({ space: Space.md }) {
        if (input.run.members.find((member) => member.id === input.record.task.memberId)) {
          this.avatar({ run: input.run, member: input.run.members.find((member) => member.id === input.record.task.memberId) as TeamMember, size: 32, ring: input.record.status === 'running' })
        }
        Column({ space: 2 }) {
          Text(input.record.task.title).fontSize(14).fontWeight(FontWeight.Medium).maxLines(this.expandedTasks.includes(input.record.task.id) ? 4 : 1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          Text(this.memberName(input.run, input.record.task.memberId) + ' · ' + teamStatus(input.record.status)).fontSize(Font.caption)
            .fontColor(input.record.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        this.taskGlyph({ status: input.record.status })
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.expandedTasks.includes(input.record.task.id) ? 180 : 0 })
      }.id('team-task-' + input.run.id + '-' + input.record.task.id).width('100%').constraintSize({ minHeight: 52 })
      .accessibilityText(input.record.task.title + '，' + this.memberName(input.run, input.record.task.memberId) + '，' + teamStatus(input.record.status))
      .onClick(() => this.animate(() => { this.expandedTasks = this.toggleList(this.expandedTasks, input.record.task.id); }))
      if (this.expandedTasks.includes(input.record.task.id)) {
        Column({ space: Space.sm }) {
          // The result leads; the brief the coordinator wrote is usually long, so it starts clamped.
          ForEach(input.record.attempts.map((attempt) => attempt.id), (attemptId: string, index: number) => {
            this.attemptView({ record: input.record,
              attempt: input.record.attempts.find((attempt) => attempt.id === attemptId) as TeamAttempt, index: index })
          }, (attemptId: string) => attemptId)
          if (!input.record.attempts.length) { Text(t("等待前置任务或空闲员工")).fontSize(13).fontColor($r('app.color.text_tertiary')) }
          this.label(t("任务说明"))
          Text(input.record.task.instructions).fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary'))
            .maxLines(this.expandedBriefs.includes(input.record.task.id) ? 200 : 3).textOverflow({ overflow: TextOverflow.Ellipsis })
            .accessibilityText(input.record.task.instructions)
            .onClick(() => this.animate(() => { this.expandedBriefs = this.toggleList(this.expandedBriefs, input.record.task.id); }))
          if (input.record.task.dependencies.length) {
            Text(t("依赖：") + input.record.task.dependencies.map((id) => input.run.tasks.find((item) => item.task.id === id)?.task.title || id).join('、'))
              .fontSize(12).lineHeight(18).fontColor($r('app.color.text_tertiary'))
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 44, bottom: Space.sm })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -4 })))
      }
    }.width('100%')
  }

  @Builder
  card(input: TeamCardInput) {
    Column() {
      Column({ space: Space.md }) {
        Column({ space: 10 }) {
          Row({ space: Space.sm }) {
            Column() {
              SymbolGlyph($r('sys.symbol.person_2')).fontSize(16).fontColor([$r('app.color.on_accent_container')])
            }.width(28).height(28).borderRadius(9).justifyContent(FlexAlign.Center).backgroundColor($r('app.color.accent_container'))
            Text(input.run.ownerMessageId ? t("Agent 团队") : t("历史团队")).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).layoutWeight(1)
            this.statusPill({ status: input.run.status })
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.expanded ? 180 : 0 })
          }.width('100%')
          if (input.run.goal) {
            Text(input.run.goal).fontSize(13).lineHeight(19).maxLines(this.expanded ? 6 : 2)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
          }
          Row({ space: Space.sm }) {
            Progress({ value: this.doneCount(input.run), total: Math.max(1, input.run.tasks.length), type: ProgressType.Linear })
              .layoutWeight(1).color(input.run.status === 'failed' ? $r('app.color.danger') : $r('app.color.accent'))
              .backgroundColor($r('app.color.surface_variant')).style({ strokeWidth: 4, strokeRadius: 2 })
            Text(this.doneCount(input.run) + '/' + input.run.tasks.length + t(" 任务")).fontSize(Font.caption)
              .fontColor($r('app.color.text_tertiary'))
          }.width('100%')
          if (!this.expanded) {
            Row() {
              Row() {
                ForEach(input.run.members.slice(0, 5).map((member) => member.id), (memberId: string, index: number) => {
                  Column() {
                    this.avatar({ run: input.run, member: input.run.members.find((member) => member.id === memberId) as TeamMember, size: 26, ring: true })
                  }.margin({ left: index === 0 ? 0 : -6 })
                }, (memberId: string) => memberId)
              }
              Text(input.run.members.map((member) => member.name).join('、')).fontSize(Font.caption).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).margin({ left: Space.sm })
                .fontColor($r('app.color.text_secondary'))
            }.width('100%')
          }
        }.id('chat-team-' + input.run.id).width('100%').alignItems(HorizontalAlign.Start)
        .accessibilityText((input.run.ownerMessageId ? t("Agent 团队，") : t("历史团队，")) + teamStatus(input.run.status) + '，' +
          this.doneCount(input.run) + '/' + input.run.tasks.length + t(" 个任务完成，") + (this.expanded ? t("点按收起") : t("点按展开")))
        .onClick(() => this.animate(() => { this.expanded = !this.expanded; }))
        if (this.expanded) {
          Column() {
            if (input.run.error) {
              Text(input.run.error).fontSize(13).lineHeight(19).width('100%').margin({ bottom: Space.sm })
                .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(Radius.sm)
                .fontColor($r('app.color.danger')).backgroundColor($r('app.color.danger_container'))
                .copyOption(CopyOptions.LocalDevice)
            }
            // Stable IDs retain native rows. Resolve each ID through the live builder input so
            // new snapshots update existing rows instead of capturing their initial objects.
            ForEach(input.run.tasks.map((record) => record.task.id), (taskId: string, index: number) => {
              if (index > 0) { Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 44 }) }
              this.taskRow({ run: input.run, record: input.run.tasks.find((record) => record.task.id === taskId) as TeamTaskRecord })
            }, (taskId: string) => taskId)
            Row({ space: Space.sm }) {
              Text(this.usage(input.run)).fontSize(11).layoutWeight(1).maxLines(2).fontColor($r('app.color.text_tertiary'))
              Row({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.folder')).fontSize(14).fontColor([$r('app.color.on_accent_container')])
                Text(t("查看文件")).fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.on_accent_container'))
              }.id('team-files-' + input.run.id).height(30).padding({ left: 10, right: 12 }).borderRadius(15)
              .backgroundColor($r('app.color.accent_container')).clickEffect(Motion.press)
              .opacity(this.app.busy ? 0.5 : 1).enabled(!this.app.busy).onClick(() => this.onFiles())
            }.width('100%').margin({ top: Space.sm })
          }.width('100%').padding({ top: 4 }).border({ width: { top: 0.5 }, color: $r('app.color.divider') })
          .transition(TransitionEffect.OPACITY)
        }
      }.width('100%').padding(14)
    }.width('100%').borderRadius(Radius.lg).clip(true).backgroundColor($r('app.color.surface'))
    .border({ width: 0.5, color: input.run.status === 'running' ? $r('app.color.accent_outline') : $r('app.color.divider') })
  }

  build() {
    if (this.current()) { this.card({ run: this.current() as TeamRun }) }
  }
}

@Component
export struct ChatTeamCard {
  @ObjectLink app: ChatViewModel;
  @Prop messageId: string = '';
  onFiles: () => void = () => {};
  build() {
    Column({ space: Space.sm }) {
      ForEach(this.app.teams.filter((run) => (run.ownerMessageId || '') === this.messageId), (run: TeamRun) => {
        ChatTeamRun({ app: this.app, runId: run.id, onFiles: this.onFiles })
      }, (run: TeamRun) => run.id)
    }.width('100%')
  }
}
