import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SwitchRow } from '../common/Widgets';
import { t } from '../model/I18n';
import { CollaborationThread, CollaborationThreadState, CollaborationMessageState, CollaborationTool } from '../model/DeviceCollaboration';
import { DeviceCollaboration } from '../services/DeviceCollaboration';
import { CollaborationDevice, NativeDeviceCollaboration } from '../services/NativeDeviceCollaboration';
import { LanDeviceCollaboration } from '../services/LanDeviceCollaboration';
import { MarkdownView } from './MarkdownView';

export function collaborationStatus(thread: CollaborationThread): string {
  if (thread.phase === 'idle' && thread.status === 'stopped') { return t('已停止'); }
  if (thread.error) { return t('执行出错'); }
  if (thread.phase === 'running') { return t('执行中'); }
  if (thread.phase === 'compacting') { return t('压缩中'); }
  if (thread.phase === 'memory') { return t('整理记忆中'); }
  if (thread.status === 'stopped') { return t('已停止'); }
  if (thread.status === 'complete') { return t('已完成'); }
  return t('空闲');
}

@Component
struct CollaborationThreadRow {
  @ObjectLink thread: CollaborationThreadState;
  @Prop selected: boolean = false;
  onSelect: () => void = () => {};
  build() {
    NavRow({ title: this.thread.title, subtitle: collaborationStatus(this.thread) + ' · ' + this.thread.model +
      (this.thread.queued ? ' · ' + t('排队 {0}', [this.thread.queued]) : ''),
      active: this.selected, trailing: 'select', compId: 'collaboration-thread-' + this.thread.id, onTap: this.onSelect })
  }
}

@Component
struct CollaborationMessageCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink message: CollaborationMessageState;
  build() {
    Column({ space: 8 }) {
      Text(this.message.role === 'user' ? t('用户') : t('助手')).fontSize(12).fontColor($r('app.color.text_secondary'))
      if (this.message.thinking && !this.message.content && this.message.status === 'generating') {
        Text(t('正在思考…')).fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      ForEach(this.message.tools, (tool: CollaborationTool) => {
        Text(tool.name + ' · ' + tool.status).fontSize(12).fontColor($r('app.color.text_secondary'))
      }, (tool: CollaborationTool) => tool.id + ':' + tool.status)
      if (this.message.content) { MarkdownView({ content: this.message.content, streaming: this.message.status === 'generating' }) }
      if (this.message.error) {
        Text(this.message.error).fontSize(13)
          .fontColor(this.message.status === 'stopped' ? $r('app.color.text_secondary') : $r('app.color.danger'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).borderRadius(12)
      .backgroundColor(this.message.role === 'user' ? this.appearance.accentContainer : $r('app.color.surface'))
  }
}

@Component
export struct DeviceCollaborationPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink model: DeviceCollaboration;
  @ObjectLink connection: NativeDeviceCollaboration;
  @ObjectLink lan: LanDeviceCollaboration;
  @State private panelWidth: number = 0;
  @State private listDevice: string = 'local';
  @State private composing: boolean = false;
  @State private followOutput: boolean = true;
  @State private lanMode: boolean = false;
  private scroller: Scroller = new Scroller();

  private joinLan(): void {
    if (this.lan.busy || !this.lan.input.trim()) { return; }
    this.getUIContext().getFocusController().clearFocus();
    this.connection.disconnect(); this.model.error = ''; this.lan.join();
  }

  @Builder
  connectionHeader() {
    Column({ space: 8 }) {
      GroupCard() {
        SwitchRow({ title: t('启用多设备协同'), isOn: this.connection.enabled, disabled: this.connection.busy,
          compId: 'collaboration-enable', subtitle: t('连接后双方可查看会话并发起任务。关闭开关即可结束连接。'),
          onChange: (value: boolean) => { this.connection.setEnabled(value); } })
      }
      if ((this.lanMode ? this.lan.error : this.connection.error) || this.model.error) {
        Banner({ text: (this.lanMode ? this.lan.error : this.connection.error) || this.model.error, compId: 'collaboration-error' })
      }
      if (this.model.connected) {
        Text(this.lan.active ? t('连接方式：局域网直连') : t('连接方式：鸿蒙原生协同')).fontSize(12).fontColor($r('app.color.text_secondary'))
        Row({ space: 8 }) {
          Text(t('已连接：{0}', [this.model.peerName])).fontSize(14).layoutWeight(1).fontColor($r('app.color.text_primary'))
          Button(t('断开')).attributeModifier(Btn.text).id('collaboration-disconnect').onClick(() => this.connection.disconnect())
        }.width('100%')
      } else if (this.connection.enabled) {
        Row({ space: 8 }) {
          Button(t('鸿蒙原生协同')).attributeModifier(Btn.text).id('collaboration-native-mode')
            .onClick(() => { this.lan.stop(); this.lanMode = false; this.model.error = ''; })
          Button(t('局域网直连')).attributeModifier(Btn.text).id('collaboration-lan-mode')
            .onClick(() => { this.connection.disconnect(); this.lanMode = true; this.model.error = ''; })
        }.width('100%')
        if (this.lanMode) {
          this.lanSetup()
        } else {
        Row() {
          Text(t('两台设备均需开启 Wi-Fi、蓝牙，并登录同一华为账号。')).fontSize(12)
            .fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(t('刷新设备')).attributeModifier(Btn.text).id('collaboration-refresh').onClick(() => this.connection.refresh())
        }.width('100%')
        Scroll() {
          Column() {
            ForEach(this.connection.devices, (device: CollaborationDevice) => {
              NavRow({ title: device.name, subtitle: t('连接设备'), compId: 'collaboration-connect-' + device.name,
                disabled: this.connection.busy, onTap: () => { this.connection.connect(device); } })
            }, (device: CollaborationDevice) => device.id)
            if (!this.connection.devices.length) {
              Text(t('未发现可信设备，请检查两端系统的多设备协同设置后刷新。')).fontSize(13)
                .fontColor($r('app.color.text_secondary')).padding(12)
            }
          }.width('100%')
        }.width('100%').constraintSize({ maxHeight: 150 })
        }
      }
    }.width('100%').padding({ left: Space.page, right: Space.page, top: 8 })
  }
  @Builder
  lanSetup() {
    Column({ space: 8 }) {
      Text(t('两端连接同一 Wi-Fi。在一端生成连接码，复制到另一端连接。')).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      Row({ space: 8 }) {
        Button(t('生成连接码')).attributeModifier(Btn.tonalSmall).id('collaboration-lan-host').enabled(!this.lan.busy)
          .onClick(() => { this.connection.disconnect(); this.lan.host(); })
        if (this.lan.invitation) {
          Button(t('复制连接码')).attributeModifier(Btn.textSmall).id('collaboration-lan-copy').onClick(() => { this.lan.copyInvitation(); })
          Button(t('取消')).attributeModifier(Btn.textSmall).onClick(() => this.lan.stop())
        }
      }.width('100%')
      if (this.lan.invitation) {
        Text(this.lan.invitation).id('collaboration-lan-invitation').fontSize(10).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_secondary')).width('100%')
        Text(t('连接码 5 分钟有效，仅分享给自己的设备。关闭协同会撤销连接码。')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
      }
      TextInput({ text: this.lan.input, placeholder: t('粘贴另一台设备的连接码') }).id('collaboration-lan-input')
        .width('100%').maxLength(200).enterKeyType(EnterKeyType.Go)
        .onChange((value: string) => { this.lan.input = value; }).onSubmit(() => this.joinLan())
      Row() {
        Button(t('连接')).attributeModifier(Btn.tonalSmall).id('collaboration-lan-join')
          .enabled(!this.lan.busy && !!this.lan.input.trim()).onClick(() => this.joinLan())
      }.width('100%')
    }.width('100%')
  }
  @Builder
  threadList() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button(t('本机')).attributeModifier(Btn.text).id('collaboration-local-tab').onClick(() => { this.listDevice = 'local'; })
        Button(this.model.peerName || t('另一台设备')).attributeModifier(Btn.text).id('collaboration-peer-tab')
          .onClick(() => { this.listDevice = 'peer'; })
        Blank()
      }.width('100%')
      Button(this.listDevice === 'local' ? t('在本机新建会话') : t('在 {0} 新建会话', [this.model.peerName || t('另一台设备')]))
        .attributeModifier(Btn.tonal).id('collaboration-new').width('100%')
        .enabled(!this.model.submitting && (this.listDevice === 'local' || this.model.connected))
        .onClick(() => { this.model.create(this.listDevice); })
      Scroll() {
        Column() {
          if (this.listDevice === 'peer' && this.model.connected && !this.model.peerCatalogReady) {
            Text(t('正在同步…')).fontSize(13).fontColor($r('app.color.text_secondary')).padding(12)
          }
          ForEach(this.listDevice === 'local' ? this.model.localThreads : this.model.peerThreads, (thread: CollaborationThreadState) => {
            CollaborationThreadRow({ thread: thread, selected: this.model.selectedDevice === this.listDevice && this.model.selectedId === thread.id,
              onSelect: () => { this.followOutput = true; this.model.select(this.listDevice, thread.id); } })
            RowDivider()
          }, (thread: CollaborationThreadState) => this.listDevice + ':' + thread.id)
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.width(this.panelWidth >= 700 ? 280 : '100%').height(this.panelWidth >= 700 ? '100%' : 190)
      .padding(12).backgroundColor($r('app.color.surface'))
  }
  @Builder
  conversation() {
    Column({ space: 8 }) {
      if (this.model.selectedId) {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(this.model.output?.thread.title || t('正在同步…')).fontWeight(FontWeight.Medium).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
            Text(t('执行设备：{0}', [this.model.selectedDevice === 'local' ? t('本机') : this.model.peerName]))
              .fontSize(12).fontColor($r('app.color.text_secondary'))
            if (this.model.output) {
              Text(collaborationStatus(this.model.output.thread)).fontSize(12).fontColor($r('app.color.text_secondary'))
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.model.output?.thread.phase === 'running') {
            Button(t('停止')).attributeModifier(Btn.text).id('collaboration-stop')
              .enabled(this.model.selectedDevice === 'local' || this.model.connected).onClick(() => { this.model.stop(); })
          }
        }.width('100%')
        if (this.model.selectedDevice === 'peer' && !this.model.connected) {
          Banner({ text: t('设备连接已断开，远端状态尚未更新。'), danger: false })
        }
        if (this.model.output?.thread.error) {
          Banner({ text: this.model.output.thread.error, danger: this.model.output.thread.status !== 'stopped' })
        }
        Scroll(this.scroller) {
          Column({ space: 12 }) {
            ForEach(this.model.messages, (message: CollaborationMessageState) => { CollaborationMessageCard({ message: message }) },
              (message: CollaborationMessageState) => this.model.selectedDevice + ':' + this.model.selectedId + ':' + message.id)
          }.width('100%').padding({ bottom: 12 }).onAreaChange(() => {
            if (this.followOutput) { this.scroller.scrollEdge(Edge.Bottom); }
          })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            if (state === ScrollState.Scroll) { this.followOutput = false; }
            return { offsetRemain: offset };
          }).onScrollEdge((edge: Edge) => { if (edge === Edge.Bottom) { this.followOutput = true; } })
        Text(t('使用执行设备的模型和工具；工具确认与文件操作在执行设备完成。')).fontSize(11)
          .fontColor($r('app.color.text_secondary')).width('100%')
        TextArea({ text: this.model.draft, placeholder: t('发送消息，执行中的会话会将新指令加入队列') })
          .id('collaboration-input').height(76).maxLength(24000).onChange((value: string) => { this.model.draft = value; })
          .onFocus(() => { this.composing = true; }).onBlur(() => { this.composing = false; })
        Button(this.model.submitting ? t('提交中…') : t('发送')).attributeModifier(Btn.primary).id('collaboration-send').width('100%')
          .enabled(!this.model.submitting && !!this.model.draft.trim() && !!this.model.output &&
            (this.model.selectedDevice === 'local' || this.model.connected)).onClick(() => {
              this.getUIContext().getFocusController().clearFocus(); this.composing = false; this.followOutput = true; this.model.submit();
            })
      } else {
        Blank()
        Text(t('选择一段会话，或选择执行设备后新建。')).fontColor($r('app.color.text_secondary')).fontSize(15)
        Blank()
      }
    }.layoutWeight(1).width('100%').height('100%').padding(12)
  }
  build() {
    Column({ space: 12 }) {
      if (!this.composing || this.panelWidth >= 700) { this.connectionHeader() }
      Flex({ direction: this.panelWidth >= 700 ? FlexDirection.Row : FlexDirection.Column }) {
        if (!this.composing || this.panelWidth >= 700) { this.threadList() }
        this.conversation()
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
      .onAreaChange((_old: Area, area: Area) => { this.panelWidth = Number(area.width); })
  }
}
