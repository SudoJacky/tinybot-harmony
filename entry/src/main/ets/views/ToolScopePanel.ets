import { AppearanceStyle } from '../common/AppearanceStyle';
import { Space, systemInsets } from '../common/Theme';
import { GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { AgentMode, AGENT_MODES, agentModeName } from '../model/AgentMode';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { CustomToolsPanel } from './CustomToolsPanel';

@Component
export struct ToolScopePanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  @State private insetBottom: number = 0;

  aboutToAppear(): void {
    // A large sheet floats over the window, not inside the page's safe area: the
    // last capability row would otherwise sit under the navigation indicator.
    systemInsets(this.getUIContext()).then((insets: number[]) => { this.insetBottom = insets[1]; });
  }

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
        GroupCard() {
          Column() {
            ForEach(AGENT_MODES, (mode: AgentMode, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: agentModeName(mode), trailing: 'select', active: this.thread.agentMode === mode,
                compId: 'conversation-tool-scope-' + mode, disabled: !this.editable(), onTap: () => this.selectMode(mode) })
            }, (mode: AgentMode) => mode)
          }
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md })
      if (this.thread.agentMode === 'custom') {
        CustomToolsPanel({ app: this.app, thread: this.thread }).layoutWeight(1)
      }
    }.width('100%').height(this.thread.agentMode === 'custom' ? '100%' : undefined)
      .padding({ bottom: Space.lg + this.insetBottom })
  }
}
