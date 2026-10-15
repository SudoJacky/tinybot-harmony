import { AppearanceStyle } from '../common/AppearanceStyle';
import { Font, Space } from '../common/Theme';
import { GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { AgentMode, AGENT_MODES, agentModeName } from '../model/AgentMode';
import { t } from '../model/I18n';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { CustomToolsPanel } from './CustomToolsPanel';

@Component
export struct ToolScopePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;

  private editable(): boolean {
    return this.app.ready && !this.app.busy && !this.thread.archived && this.app.saveError.length === 0 && this.thread.id === this.app.active.id;
  }

  private async selectMode(mode: AgentMode): Promise<void> {
    if (!this.editable()) { return; }
    await this.app.setAgentMode(mode);
  }

  build() {
    Column({ space: Space.md }) {
      Column({ space: Space.md }) {
        Text(t('仅用于当前对话，选择会随下一条消息保存。')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
          .fontColor($r('app.color.text_secondary')).width('100%')
        GroupCard() {
          Column() {
            ForEach(AGENT_MODES, (mode: AgentMode, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: agentModeName(mode), trailing: 'select', active: this.thread.agentMode === mode,
                compId: 'conversation-tool-scope-' + mode, disabled: !this.editable(), onTap: () => this.selectMode(mode) })
            }, (mode: AgentMode) => mode)
          }
        }
        Text(t('工具仍受全局权限和服务配置限制。')).fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
          .fontColor($r('app.color.text_secondary')).width('100%')
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md })
      if (this.thread.agentMode === 'custom') {
        CustomToolsPanel({ app: this.app, thread: this.thread }).layoutWeight(1)
      }
    }.width('100%').height(this.thread.agentMode === 'custom' ? '100%' : undefined).padding({ bottom: Space.lg })
  }
}
