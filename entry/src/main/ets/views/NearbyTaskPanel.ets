import { getLocale, t } from '../model/I18n';
import { NearbyTaskStatus, NearbyTaskControl, TaskApproval } from '../model/NearbyTask';
import { PendingInput } from '../model/PendingInput';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { InputFormCard } from './InputFormCard';

@Component
export struct NearbyTaskPanel {
  @Prop status: NearbyTaskStatus | undefined = undefined;
  @Prop busy: boolean = false;
  @Prop hasDraft: boolean = false;
  onControl: (control: NearbyTaskControl) => void = () => {};
  onSteer: () => void = () => {};

  private label(): string {
    if (!this.status?.connected) { return t('执行端未连接'); }
    const task = this.status.task;
    if (task?.approval) { return task.approval.form ? t('等待填写表单') : t('等待工具审批'); }
    if (task?.queuePaused && task.pendingInputs.length) { return t('待发送队列已暂停'); }
    return task?.running ? t('正在执行') : t('执行端已就绪');
  }
  private control(action: 'stop' | 'resume' | 'remove-input', inputId?: string): void {
    this.onControl({ action: action, runId: this.status?.task?.runId || '', inputId: inputId });
  }
  private approve(approval: TaskApproval, allowed: boolean, values?: string[]): void {
    this.onControl({ action: approval.form ? 'form' : 'approve', runId: this.status?.task?.runId || '',
      approvalId: approval.id, allowed: allowed, values: values });
  }
  build() {
    Column({ space: Space.sm }) {
      Row({ space: Space.sm }) {
        Text(this.label()).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        if (this.status?.task?.running) {
          if (this.hasDraft) {
            Button(t('追加')).id('remote-steer').attributeModifier(Btn.plainSmall)
              .enabled(this.status?.connected === true && this.status?.task?.acceptingSteering === true && !this.busy).onClick(this.onSteer)
          }
          Button(t('停止')).id('remote-stop').attributeModifier(Btn.tonalSmall)
            .enabled(this.status?.connected === true && !this.busy).onClick(() => this.control('stop'))
        }
      }.width('100%')
      if (!this.status?.connected && this.status?.updatedAt) {
        Text(t('最后更新 · {0}', [new Date(this.status.updatedAt).toLocaleTimeString(getLocale())]))
          .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
      }
      ForEach(this.status?.task?.approval ? [this.status.task.approval] : [], (approval: TaskApproval) => {
        if (approval.form) {
          InputFormCard({ form: approval.form, disabled: !this.status?.connected || this.busy,
            onSubmit: (values: string[]) => this.approve(approval, true, values), onCancel: () => this.approve(approval, false) })
        } else {
          Column({ space: Space.sm }) {
            Text(approval.title).fontSize(15).fontColor($r('app.color.text_primary')).width('100%')
            Scroll() {
              Text(approval.details).fontSize(12).fontFamily('monospace').copyOption(CopyOptions.LocalDevice).width('100%')
            }.constraintSize({ maxHeight: 140 }).width('100%')
            Row({ space: Space.sm }) {
              Button(t('拒绝')).attributeModifier(Btn.plainSmall).onClick(() => this.approve(approval, false))
              Button(t('允许本次')).attributeModifier(Btn.primarySmall).onClick(() => this.approve(approval, true))
            }.enabled(this.status?.connected === true && !this.busy)
          }.padding(Space.md).backgroundColor($r('app.color.surface')).borderRadius(Radius.lg).width('100%')
        }
      }, (approval: TaskApproval) => approval.id)
      if (this.status?.task?.pendingInputs.length) {
        Column({ space: Space.sm }) {
          ForEach(this.status.task.pendingInputs, (input: PendingInput) => {
            Row({ space: Space.sm }) {
              Text(input.text).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(Font.caption).layoutWeight(1)
              Button(t('撤回')).attributeModifier(Btn.plainSmall).onClick(() => this.control('remove-input', input.id))
                .enabled(this.status?.connected === true && !this.busy)
            }.width('100%')
          }, (input: PendingInput) => input.id)
          if (this.status.task.queuePaused && !this.status.task.running) {
            Button(t('继续执行')).id('remote-resume').attributeModifier(Btn.tonalSmall)
              .enabled(this.status.connected && !this.busy).onClick(() => this.control('resume', this.status?.task?.pendingInputs[0]?.id))
          }
        }.width('100%').padding(Space.sm).backgroundColor($r('app.color.surface')).borderRadius(Radius.lg)
      }
    }.width('100%')
  }
}
