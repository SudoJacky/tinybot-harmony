import { common } from '@kit.AbilityKit';
import { liveSyncProbe } from '../services/LiveSyncProbe';

@Component
export struct LiveSyncProbePanel {
  @StorageProp('tinybot.probe.armed') private armed: boolean = false;
  @StorageProp('tinybot.probe.connected') private connected: boolean = false;
  @StorageProp('tinybot.probe.status') private status: string = '';
  @StorageProp('tinybot.probe.remote') private remote: string = '';
  @StorageProp('tinybot.probe.results') private results: string = '';
  @State private error: string = '';
  @State private busy: boolean = false;

  private async start(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (this.armed) { await liveSyncProbe.connect(context); }
      else { await liveSyncProbe.arm(context); }
    } catch (error) { this.error = (error as Error).message; }
    finally { this.busy = false; }
  }

  build() {
    Column({ space: 12 }) {
      Text('实时同步测试').fontSize(20).fontWeight(FontWeight.Bold)
      Text(this.error || this.status || '仅发送合成数据').id('probe-status')
      Text(this.remote).id('probe-remote')
      Text(this.results).id('probe-results')
      if (!this.connected) {
        Button(this.armed ? '连接另一台设备' : '启用测试').id(this.armed ? 'probe-connect' : 'probe-arm')
          .enabled(!this.busy).onClick(() => this.start())
      } else {
        Button('发送测试流').id('probe-sample').onClick(() => liveSyncProbe.sample())
      }
      Button('结束测试').id('probe-exit').onClick(() => liveSyncProbe.exit())
    }.width('92%').constraintSize({ maxWidth: 480 }).padding(24).borderRadius(20)
      .backgroundColor($r('app.color.surface')).shadow({ radius: 14, color: '#66000000' })
  }
}
