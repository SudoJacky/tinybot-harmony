import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Space } from '../common/Theme';
import { Banner, GroupCard, RowDivider, SectionHeader, SwitchRow, Segmented } from '../common/Widgets';
import { t } from '../model/I18n';
import { Diagnostics, PerfEvent, PerfSnapshot, PerfSummary } from '../model/Diagnostics';
import { LOG_LEVELS, LogLevel, logRank } from '../model/DiagnosticLog';
import { DeveloperDiagnostics } from '../services/DeveloperDiagnostics';
import { exportFile, shareFile } from '../services/NativeActions';

@Component
export struct DeveloperPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.developer.enabled') private developerEnabled: boolean = false;
  @StorageProp('tinybot.developer.recording') @Watch('syncTimer') private recording: boolean = false;
  @StorageProp('tinybot.developer.cpu') private cpuRecording: boolean = false;
  @StorageProp('tinybot.developer.error') private adapterError: string = '';
  @StorageProp('tinybot.foreground') @Watch('syncTimer') private foreground: boolean = true;
  @State private stats: PerfSnapshot = Diagnostics.snapshot(false);
  @State private recent: PerfEvent[] = [];
  @State private runtimeLogs: PerfEvent[] = [];
  @State private minimumLevel: LogLevel = 'info';
  @State private detailed: boolean = true;
  @State private frames: boolean = false;
  @State private busy: boolean = false;
  @State private error: string = '';
  private timer: number = -1;
  private mounted: boolean = false;
  private sequence: number = 0;
  private session: number = -1;
  onDisabled: () => void = () => {};

  aboutToAppear(): void {
    this.mounted = true; this.detailed = Diagnostics.detailed; this.minimumLevel = Diagnostics.logLevel;
    this.frames = DeveloperDiagnostics.framesEnabled(); this.refresh(); this.syncTimer();
  }
  aboutToDisappear(): void { this.mounted = false; clearInterval(this.timer); this.timer = -1; }
  private syncTimer(): void {
    clearInterval(this.timer); this.timer = -1;
    if (this.mounted && this.foreground && this.recording) { this.timer = setInterval(() => this.refresh(), 2000); }
  }
  private refresh(): void {
    this.stats = Diagnostics.snapshot(false);
    if (this.session !== this.stats.session) { this.session = this.stats.session; this.sequence = 0; this.recent = []; this.runtimeLogs = []; }
    const events = Diagnostics.eventsSince(this.sequence);
    if (events.length) { this.sequence = events[events.length - 1].seq; }
    const interesting = events.filter((event: PerfEvent) => event.duration >= 8 || event.name.startsWith('os.') ||
      event.name === 'user.marker' || event.name === 'diagnostics.error' || event.name === 'ui.eventLoopDelay');
    this.recent = this.recent.concat(interesting).slice(-40);
    this.runtimeLogs = this.runtimeLogs.concat(events.filter((event: PerfEvent) => event.log !== undefined)).slice(-40);
  }
  private value(value: number): string { return value.toFixed(value < 10 ? 2 : 1); }
  private metricLine(name: string): string {
    // Keyed builders retain their original objects. Resolve the current snapshot by its stable name.
    const metric = this.stats.metrics.find((value: PerfSummary) => value.name === name);
    if (!metric) { return ''; }
    return t('次数 {0} · 均值 {1} · P95 ≤ {2} · 最大 {3} {4}', [metric.count,
      this.value(metric.sum / metric.count), this.value(metric.p95Upper), this.value(metric.max), metric.unit]);
  }
  private async exportData(share: boolean): Promise<void> {
    this.busy = true; this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path = await DeveloperDiagnostics.exportCapture(context); this.refresh();
      if (share) { await shareFile(context, path, 'tinybot-performance.json'); }
      else { await exportFile(context, path, 'tinybot-performance.json'); }
    } catch (error) { this.error = t('诊断操作失败：{0}', [(error as Error).message]); }
    finally { this.busy = false; }
  }
  private async cpuProfile(exportResult: boolean): Promise<void> {
    this.error = '';
    try {
      if (!exportResult) { DeveloperDiagnostics.startCpuProfile(); }
      else { await exportFile(this.getUIContext().getHostContext() as common.UIAbilityContext,
        DeveloperDiagnostics.cpuProfilePath(), 'tinybot-cpu.cpuprofile'); }
    } catch (error) { this.error = t('诊断操作失败：{0}', [(error as Error).message]); }
  }
  private disable(): void {
    try { DeveloperDiagnostics.disable(); this.onDisabled(); }
    catch (error) { this.error = t('诊断操作失败：{0}', [(error as Error).message]); }
  }
  private clear(): void {
    this.getUIContext().showAlertDialog({ systemMaterial: this.appearance.surface, title: t('清除诊断数据'),
      message: t('停止采集并删除本机两份滚动日志及当前统计。'),
      primaryButton: { value: t('取消'), action: () => {} }, secondaryButton: { value: t('清除'), action: async () => {
        this.busy = true;
        try { await DeveloperDiagnostics.clear(); this.refresh(); }
        catch (error) { this.error = t('诊断操作失败：{0}', [(error as Error).message]); }
        finally { this.busy = false; }
      } } });
  }
  build() {
    if (this.developerEnabled) {
      Scroll() {
        Column({ space: Space.md }) {
          Banner({ text: t('统一采集性能数据与脱敏运行日志，不记录密钥、请求地址、对话正文或工具参数。采集会影响被测性能；可随时停止。'), danger: false })
          if (this.error || this.adapterError) { Banner({ text: this.error || this.adapterError, compId: 'developer-error' }) }
          GroupCard() {
            Column() {
              SwitchRow({ title: t('诊断采集'), subtitle: t('收集运行日志，前台每秒采样资源，每 250 ms 检查主线程延迟；重启后需手动开始。'),
                compId: 'developer-recording', isOn: this.recording, disabled: this.busy,
                onChange: (value: boolean) => { if (value) { DeveloperDiagnostics.start(); } else { DeveloperDiagnostics.stop(); } this.refresh(); } })
              RowDivider()
              SwitchRow({ title: t('详细事件时间线'), subtitle: t('记录各次解析、布局、增量和工具操作；关闭后保留统计、慢操作及资源数据。'),
                compId: 'developer-detailed', isOn: this.detailed, disabled: this.busy,
                onChange: (value: boolean) => { this.detailed = value; Diagnostics.detailed = value; } })
              RowDivider()
              SwitchRow({ title: t('逐帧回调采样'), subtitle: t('额外请求 Vsync，增加功耗与采样开销。统计回调间隔，不代表实际掉帧率。'),
                compId: 'developer-frames', isOn: this.frames, disabled: this.busy,
                onChange: (value: boolean) => { this.frames = value; DeveloperDiagnostics.setFrames(value); } })
            }
          }
          Text(t('采集 {0} 秒 · 环形事件 {1} 条 · 覆盖 {2} 条 · 省略 {3} 条', [Math.round(this.stats.elapsedMs / 1000),
            Math.min(this.sequence, this.stats.eventCapacity), this.stats.overwritten, this.stats.omitted]))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%').id('developer-summary')
          Row({ space: Space.sm }) {
            Button(t('记录场景标记')).fontFamily(this.appearance.fontFamily).id('developer-marker').attributeModifier(Btn.tonal)
              .layoutWeight(1).enabled(this.recording && !this.busy).onClick(() => { DeveloperDiagnostics.mark(); this.refresh(); })
            Button(t('停止并导出')).fontFamily(this.appearance.fontFamily).id('developer-export').attributeModifier(Btn.primary)
              .layoutWeight(1).enabled(!this.busy).onClick(() => this.exportData(false))
          }.width('100%')
          Button(t('停止并分享诊断包')).fontFamily(this.appearance.fontFamily).id('developer-share').attributeModifier(Btn.tonal)
            .width('100%').enabled(!this.busy).onClick(() => this.exportData(true))
          Text(t('JSON 包含完整统计、最近 12000 条事件、两份滚动日志及 Chrome Trace 时间线。P50/P95/P99 为直方图上界；资源仅当前应用进程，不含独立 Web 进程。'))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
          SectionHeader({ title: t('运行日志') })
          Segmented({ options: ['Debug', 'Info', 'Warn', 'Error'], selected: LOG_LEVELS.indexOf(this.minimumLevel),
            compIdPrefix: 'developer-log-level', onSelect: (index: number) => {
              this.minimumLevel = LOG_LEVELS[index]; Diagnostics.logLevel = this.minimumLevel;
              Diagnostics.event('logging.level', { code: index }, 0, true); this.refresh();
            } })
          Text(t('Debug {0} · Info {1} · Warn {2} · Error {3} · 覆盖 {4} · 过滤 {5} · 拒绝 {6} · 输出失败 {7}',
            [this.stats.logging.counts.debug, this.stats.logging.counts.info, this.stats.logging.counts.warn, this.stats.logging.counts.error,
              this.stats.logging.overwritten, this.stats.logging.filtered, this.stats.logging.rejected, this.stats.logging.sinkFailures]))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%').id('developer-log-summary')
          Text(t('保留最近 1000 条运行日志，独立于性能事件。关闭采集后仅保留脱敏 Warn/Error 系统日志，不写入诊断缓冲或文件。'))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
          GroupCard() {
            Column({ space: Space.sm }) {
              ForEach(this.runtimeLogs.filter((event: PerfEvent) => event.log !== undefined && logRank(event.log.level) >= logRank(this.minimumLevel)), (event: PerfEvent) => {
                Text(this.value(event.time) + ' ms · ' + event.log!.level.toUpperCase() + ' · ' + event.log!.module + '.' + event.log!.event + '\n' + JSON.stringify(event.log!.fields))
                  .fontFamily('monospace').fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
              }, (event: PerfEvent) => this.stats.session + ':' + event.seq)
            }.padding(Space.md).width('100%')
          }
          SectionHeader({ title: t('ArkTS 调用栈采样') })
          Text(t('手动采样 UI 虚拟机的 CPU 调用栈，最多 30 秒，进入后台自动停止。包含函数名与源码路径；会增加开销，不包含原生或 GPU 调用栈。'))
            .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
          Button(this.cpuRecording ? t('正在采样调用栈…') : t('开始 30 秒 CPU 采样')).fontFamily(this.appearance.fontFamily)
            .id('developer-cpu-start').attributeModifier(Btn.tonal).width('100%').enabled(!this.busy && !this.cpuRecording).onClick(() => this.cpuProfile(false))
          Button(t('停止并导出 CPU Profile')).fontFamily(this.appearance.fontFamily).id('developer-cpu-export').attributeModifier(Btn.tonal)
            .width('100%').enabled(!this.busy).onClick(() => this.cpuProfile(true))
          SectionHeader({ title: t('全程统计') })
          GroupCard() {
            Column({ space: Space.sm }) {
              if (!this.stats.metrics.length) { Text(t('开始采集后，在聊天中复现需要分析的场景。')).fontFamily(this.appearance.fontFamily) }
              ForEach(this.stats.metrics, (metric: PerfSummary) => {
                Column({ space: 4 }) {
                  Text(metric.name).fontFamily('monospace').fontSize(Font.small).fontColor($r('app.color.text_primary')).width('100%')
                  Text(this.metricLine(metric.name)).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
                }.width('100%')
              }, (metric: PerfSummary) => metric.name)
            }.padding(Space.md).width('100%')
          }
          SectionHeader({ title: t('最近慢操作与标记') })
          GroupCard() {
            Column({ space: Space.sm }) {
              ForEach(this.recent, (event: PerfEvent) => {
                Text(this.value(event.time) + ' ms · ' + event.name + ' #' + event.id + ' · ' + this.value(event.duration) + ' ms\n' + JSON.stringify(event.values))
                  .fontFamily('monospace').fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
              }, (event: PerfEvent) => this.stats.session + ':' + event.seq)
            }.width('100%').padding(Space.md)
          }
          Button(t('清除诊断数据')).fontFamily(this.appearance.fontFamily).id('developer-clear').attributeModifier(Btn.tonal)
            .width('100%').enabled(!this.busy).onClick(() => this.clear())
          Button(t('关闭开发者模式')).fontFamily(this.appearance.fontFamily).id('developer-disable').attributeModifier(Btn.textSmall)
            .width('100%').enabled(!this.busy).onClick(() => this.disable())
        }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
      }.height('100%').width('100%').align(Alignment.Top).scrollBar(BarState.Auto)
    }
  }
}
