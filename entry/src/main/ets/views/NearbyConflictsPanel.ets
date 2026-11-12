import { t } from '../model/I18n';
import { PeerSettings, PeerSettingsConflict, peerSettingsText } from '../model/PeerSyncData';
import { emptyData } from '../model/Conversation';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Space } from '../common/Theme';

function conflictValue(settings: PeerSettings, key: string): string {
  const parts = key.split(':'), id = parts.slice(1).join(':');
  if (parts[0] === 'profile') {
    const item = settings.profiles.find((item) => item.id === id);
    return item ? [item.name, item.protocol, item.baseUrl, item.models.join(', '), String(item.contextWindow || '')].filter((line) => !!line).join('\n') : t('已删除');
  }
  if (parts[0] === 'server') { const item = settings.servers.find((item) => item.id === id); return item ? item.name + '\n' + item.url : t('已删除'); }
  if (parts[0] === 'skill') { return JSON.stringify(settings.skills.find((item) => item.name === id), null, 2) || t('已删除'); }
  if (parts[0] === 'memory') { return settings.memories.find((item) => item.id === id)?.content || t('已删除'); }
  return JSON.stringify((settings as Object as Record<string, Object>)[key]);
}

@Component
export struct NearbyConflictsPanel {
  @ObjectLink app: ChatViewModel;
  @State private expanded: string = '';
  private current(): PeerSettings {
    const data = emptyData(); data.config = this.app.config; data.extensions = this.app.extensions;
    data.providerProfiles = this.app.providerProfiles; data.productivity = this.app.productivity;
    return JSON.parse(peerSettingsText(data)) as PeerSettings;
  }
  private local(key: string): string { return conflictValue(this.current(), key); }
  private label(key: string, remote: PeerSettings): string {
    const parts = key.split(':'), id = parts.slice(1).join(':'), local = this.current();
    if (parts[0] === 'profile') { return t('模型服务') + ' · ' + (remote.profiles.concat(local.profiles).find((item) => item.id === id)?.name || id); }
    if (parts[0] === 'server') { return 'MCP · ' + (remote.servers.concat(local.servers).find((item) => item.id === id)?.name || id); }
    if (parts[0] === 'skill') { return 'Skill · ' + id; }
    if (parts[0] === 'memory') { return t('记忆内容'); }
    if (key === 'userDocument') { return t('个人资料'); }
    if (key === 'autoCompact') { return t('自动压缩上下文'); }
    if (key === 'autoMemory') { return t('自动更新记忆'); }
    return t('保存会话摘要');
  }
  private async resolve(item: PeerSettingsConflict, remote: boolean): Promise<void> {
    if (!await this.app.resolveSyncConflict(item.origin, JSON.stringify(item), remote)) {
      this.getUIContext().getPromptAction().showToast({ message: this.app.error || this.app.saveError || t('请等待当前任务结束后重试。') });
    }
  }
  build() {
    Column({ space: Space.sm }) {
      ForEach(this.app.nearbyConflicts, (item: PeerSettingsConflict) => {
        Column({ space: Space.sm }) {
          Text(t('同步冲突 · 设备 {0}', [item.origin.slice(0, 8)])).fontSize(15).fontColor($r('app.color.text_primary')).width('100%')
          Text(t('两端修改了相同设置，已保留本机值。选择后只处理下列冲突项。'))
            .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
          Button(item.keys.map((key: string) => this.label(key, item.current)).join(' · ')).attributeModifier(Btn.plainSmall)
            .onClick(() => { this.expanded = this.expanded === item.origin ? '' : item.origin; })
          if (this.expanded === item.origin) {
            Scroll() {
              Column({ space: Space.sm }) {
                ForEach(item.keys, (key: string) => {
                  Text(this.label(key, item.current) + '\n' + t('本机值') + '\n' + this.local(key) + '\n\n' + t('对端值') + '\n' + conflictValue(item.current, key))
                    .fontFamily('monospace').fontSize(12).copyOption(CopyOptions.LocalDevice).width('100%')
                }, (key: string) => key)
              }
            }.constraintSize({ maxHeight: 240 }).width('100%')
          }
          Row({ space: Space.sm }) {
            Button(t('保留本机')).attributeModifier(Btn.tonalSmall).onClick(() => this.resolve(item, false))
            Button(t('采用对端')).attributeModifier(Btn.tonalSmall).onClick(() => this.resolve(item, true))
          }.enabled(!this.app.sharedBusy)
        }.padding(Space.md).width('100%')
      }, (item: PeerSettingsConflict) => item.origin)
    }.width('100%')
  }
}
