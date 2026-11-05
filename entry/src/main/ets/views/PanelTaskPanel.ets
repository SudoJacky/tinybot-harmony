import { common } from '@kit.AbilityKit';
import { PanelEntry, PanelRecord, PanelRun } from '../model/LifePanel';
import { LifePanels } from '../services/LifePanels';
import { PanelChanges } from '../services/PanelChanges';
import { Cancellation } from '../services/Cancellation';
import { Btn } from '../common/Theme';
import { t } from '../model/I18n';
@Component
export struct PanelTaskPanel {
  @StorageProp('tinybot.foreground') @Watch('activityChanged') private foreground: boolean = true;
  @Prop entry: PanelEntry;
  @State private record: PanelRecord | undefined = undefined;
  @State private error: string = '';
  private unsubscribe?: () => void;
  private cancellation: Cancellation = new Cancellation();
  private mounted: boolean = false;
  private activityChanged(): void { if (!this.foreground) { this.cancellation.cancel(); } else { this.cancellation = new Cancellation(); } }
  private panels(): LifePanels { return new LifePanels((this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().filesDir); }
  aboutToAppear(): void { this.mounted = true; this.reload(); this.unsubscribe = PanelChanges.subscribe(() => this.reload()); }
  aboutToDisappear(): void { this.mounted = false; this.unsubscribe?.(); this.cancellation.cancel(); }
  private async reload(): Promise<void> {
    try { const record = await this.panels().repository(this.entry.workspaceId).get(this.entry.panel.id); if (this.mounted) { this.record = record; } }
    catch (error) { if (this.mounted) { this.error = (error as Error).message; } }
  }
  private async action(refresh: boolean): Promise<void> {
    if (!this.foreground) { return; }
    try {
      const repository = this.panels().repository(this.entry.workspaceId); this.error = '';
      if (refresh) { await repository.refresh(this.entry.panel.id, this.cancellation); }
      else { await repository.pause(this.entry.panel.id, !this.record?.paused); }
      await this.reload();
    } catch (error) { if (this.mounted && !this.cancellation.cancelled) { this.error = (error as Error).message; } }
  }
  private status(run: PanelRun): string {
    if (run.status === 'running' && !this.panels().repository(this.entry.workspaceId).isRefreshing(this.entry.panel.id)) { return t('运行已中断'); }
    const names: Record<string, string> = { 'running': t('运行中'), 'complete': t('已完成'), 'failed': t('失败'), 'cancelled': t('已取消'), 'interrupted': t('运行已中断') };
    return names[run.status];
  }
  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text(this.record?.definition.title || this.entry.panel.definition.title).fontSize(20).fontWeight(FontWeight.Medium)
        if (this.record) {
          Text(this.record.definition.source?.type === 'agent' ? t('Agent 内容更新') : this.record.definition.source?.type === 'mail' ? t('邮箱数据刷新') : t('API / 文件数据刷新')).fontSize(14)
          Text(this.record.definition.refreshMinutes ? t('应用前台每 {0} 分钟更新', [this.record.definition.refreshMinutes!]) : t('仅手动刷新')).fontSize(12)
          if (this.record.definition.source?.prompt) { Text(this.record.definition.source.prompt).fontSize(13) }
          Row({ space: 12 }) {
            Button(this.record.paused ? t('恢复自动更新') : t('暂停自动更新')).attributeModifier(Btn.tonal).onClick(() => { this.action(false); })
            Button(t('立即刷新')).attributeModifier(Btn.primary).onClick(() => { this.action(true); })
          }
          Text(t('最近 10 次运行')).fontSize(16).fontWeight(FontWeight.Medium)
          ForEach(this.record.runs || [], (run: PanelRun) => {
            Column({ space: 4 }) {
              Text(this.status(run) + ' · ' + new Date(run.startedAt).toLocaleString()).fontSize(13)
              if (run.finishedAt) { Text(t('耗时 {0} 秒', [Math.round((run.finishedAt - run.startedAt) / 1000)])).fontSize(12) }
              if (run.error) { Text(run.error).fontSize(12).fontColor($r('app.color.danger')) }
              if (run.failure) { Text(run.failure.stage + ' · ' + run.failure.code).fontSize(12).fontColor($r('app.color.text_secondary')) }
            }.width('100%').alignItems(HorizontalAlign.Start).padding(10).backgroundColor($r('app.color.surface_variant')).borderRadius(10)
          }, (run: PanelRun) => run.id)
        }
        if (this.error) { Text(this.error).fontColor($r('app.color.danger')).fontSize(12) }
      }.padding(24).width('100%').alignItems(HorizontalAlign.Start)
    }.height('100%').width('100%')
  }
}
