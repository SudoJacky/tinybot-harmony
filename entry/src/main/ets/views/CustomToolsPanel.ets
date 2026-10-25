import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { BASIC_FILE_TOOLS, OPTIONAL_TOOL_NAMES, TOOL_CAPABILITIES, ToolCapability } from '../model/ToolGroups';
import { toolTitle, toolGroupTitle, toolCapabilityDescription } from '../model/ToolPresentation';
import { toolEnabled } from '../model/AgentMode';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { GroupCard, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';
import { Btn, Font, Space } from '../common/Theme';

@Component
export struct CustomToolsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  // The tool-scope sheet already owns one scroll container; embedded mode drops
  // the inner Scroll so the whole sheet scrolls as a single surface.
  @Prop embedded: boolean = false;

  private editable(): boolean { return !this.app.busy && !this.thread.archived && this.app.saveError.length === 0; }
  private isEnabled(capability: ToolCapability): boolean {
    return toolEnabled(capability.tools[0], { agentMode: this.thread.agentMode, disabledTools: this.thread.disabledTools });
  }
  private enabledCount(): number { return TOOL_CAPABILITIES.filter((capability) => this.isEnabled(capability)).length; }

  @Builder
  content() {
      Column({ space: Space.sm }) {
        Row({ space: Space.xs }) {
          Text(t('已开启 {0} / {1} 项能力', [this.enabledCount(), TOOL_CAPABILITIES.length])).fontFamily(this.appearance.fontFamily)
            .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(t('全部开启')).fontFamily(this.appearance.fontFamily).id('enable-optional-tools').attributeModifier(Btn.textSmall).height(36)
            .padding({ left: Space.sm, right: Space.sm }).enabled(this.editable() && this.enabledCount() < TOOL_CAPABILITIES.length)
            .onClick(() => { this.app.setDisabledTools([]); })
          Button(t('全部关闭')).fontFamily(this.appearance.fontFamily).id('disable-optional-tools').attributeModifier(Btn.textSmall).height(36)
            .padding({ left: Space.sm, right: Space.sm }).enabled(this.editable() && this.enabledCount() > 0)
            .onClick(() => { this.app.setDisabledTools(OPTIONAL_TOOL_NAMES); })
        }.id('tool-capabilities-toolbar').width('100%').padding({ left: Space.md, right: Space.md, top: Space.sm })
        SectionHeader({ title: t('基础文件工具') })
        GroupCard() {
          Text(BASIC_FILE_TOOLS.map((name) => toolTitle(name)).join('、')).fontFamily(this.appearance.fontFamily)
            .fontSize(Font.caption).lineHeight(20).fontColor($r('app.color.text_secondary'))
            .width('100%').padding(Space.md)
        }
        ForEach(['research', 'execution', 'delivery', 'extensions'], (section: string) => {
          SectionHeader({ title: toolGroupTitle(section) })
          GroupCard() {
            Column() {
              ForEach(TOOL_CAPABILITIES.filter((capability) => capability.section === section), (capability: ToolCapability, index: number) => {
                if (index > 0) { RowDivider() }
                SwitchRow({ title: toolGroupTitle(capability.id), subtitle: toolCapabilityDescription(capability.id),
                  compId: 'custom-capability-' + capability.id, isOn: this.isEnabled(capability),
                  disabled: !this.editable(),
                  onChange: (enabled: boolean) => { this.app.setToolEnabled(capability.tools[0], enabled); } })
              }, (capability: ToolCapability) => capability.id)
            }
          }
        }, (section: string) => section)
      }.width('100%').padding({ left: Space.md, right: Space.md, bottom: this.embedded ? 0 : Space.lg })
  }

  build() {
    if (this.embedded) {
      this.content()
    } else {
      Scroll() { this.content() }.width('100%').height('100%').scrollBar(BarState.Auto)
    }
  }
}
