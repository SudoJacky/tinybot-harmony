import { common } from '@kit.AbilityKit';
import { t } from '../model/I18n';
import { TIMED_DIAGNOSTICS_FILE } from '../model/Diagnostics';
import { exportFile } from '../services/NativeActions';
import { DeveloperDiagnostics } from '../services/DeveloperDiagnostics';
import { Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SwitchRow } from '../common/Widgets';

@Component
export struct DiagnosticLogsCard {
  @StorageProp('tinybot.diagnostics.recording') private recording: boolean = false;
  @StorageProp('tinybot.diagnostics.available') private available: boolean = false;
  @StorageProp('tinybot.diagnostics.saving') private saving: boolean = false;
  @StorageProp('tinybot.diagnostics.saveError') private saveError: boolean = false;
  @StorageProp('tinybot.developer.recording') private developerRecording: boolean = false;
  @State private exporting: boolean = false;
  @State private error: string = '';

  private setRecording(enabled: boolean): void {
    this.error = '';
    try { DeveloperDiagnostics.setTimedRecording(enabled); }
    catch (error) { this.error = t('诊断操作失败：{0}', [(error as Error).message]); }
  }

  private async exportLogs(): Promise<void> {
    if (this.recording || this.saving || this.exporting || !this.available) { return; }
    this.exporting = true; this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await exportFile(context, await DeveloperDiagnostics.timedCapturePath(), TIMED_DIAGNOSTICS_FILE);
    } catch (error) { this.error = t('诊断操作失败：{0}', [(error as Error).message]); }
    finally { this.exporting = false; }
  }

  build() {
    GroupCard() {
      Column() {
        SwitchRow({ title: t('诊断日志'), icon: $r('sys.symbol.doc_text'),
          subtitle: this.developerRecording && !this.recording ? t('请先停止开发者模式中的诊断采集。') :
            t('收集脱敏的详细日志，5 分钟后自动停止。'), compId: 'about-diagnostic-logs',
          isOn: this.recording, disabled: this.saving || this.exporting || (this.developerRecording && !this.recording),
          onChange: (enabled: boolean) => this.setRecording(enabled) })
        RowDivider()
        NavRow({ title: t('导出诊断日志'), icon: $r('sys.symbol.square_and_arrow_down'),
          value: this.saving ? t('正在保存…') : '', compId: 'about-export-diagnostic-logs',
          disabled: this.recording || this.saving || this.exporting || !this.available, onTap: () => this.exportLogs() })
        if (this.error || this.saveError) {
          Banner({ text: this.error || t('诊断日志保存失败，请重试。'), compId: 'about-diagnostic-error' })
            .margin({ left: Space.md, right: Space.md, bottom: Space.sm })
        }
      }
    }
  }
}
