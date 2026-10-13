import { t } from '../model/I18n';
import { BASIC_FILE_TOOLS, OPTIONAL_TOOL_NAMES, TOOL_GROUPS, ToolGroup } from '../model/ToolGroups';
import { toolTitle, toolGroupTitle } from '../model/ToolPresentation';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { GroupCard, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';
import { Btn, Font, Space } from '../common/Theme';

@Component
export struct CustomToolsPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;

  private editable(): boolean { return !this.app.busy && !this.thread.archived && this.app.saveError.length === 0; }

  build() {
    Scroll() {
      Column({ space: Space.sm }) {
        Text(t('基础文件工具始终保留，其余工具可以逐个开关。工具仍受服务配置和授权限制。'))
          .fontSize(Font.caption).lineHeight(20).fontColor($r('app.color.text_secondary'))
          .width('100%').padding({ left: Space.md, right: Space.md, top: Space.md })
        Text(t('选择会随下一条消息保存。')).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
          .width('100%').padding({ left: Space.md, right: Space.md })
        Text(t('已开启 {0} / {1} 个可选工具', [OPTIONAL_TOOL_NAMES.length - this.thread.disabledTools.length, OPTIONAL_TOOL_NAMES.length]))
          .fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%').padding({ left: Space.md, right: Space.md })
        Row({ space: Space.sm }) {
          Button(t('全部开启')).id('enable-optional-tools').attributeModifier(Btn.plainSmall).height(40)
            .enabled(this.editable()).onClick(() => { this.app.setDisabledTools([]); })
          Button(t('关闭可选工具')).id('disable-optional-tools').attributeModifier(Btn.plainSmall).height(40)
            .enabled(this.editable()).onClick(() => { this.app.setDisabledTools(OPTIONAL_TOOL_NAMES); })
        }.width('100%').padding({ left: Space.md, right: Space.md })
        SectionHeader({ title: t('基础文件工具'), caption: t('基础工具，始终开启') })
        GroupCard() {
          Text(BASIC_FILE_TOOLS.map((name) => toolTitle(name)).join('、'))
            .fontSize(Font.caption).lineHeight(20).fontColor($r('app.color.text_secondary'))
            .width('100%').padding(Space.md)
        }
        ForEach(TOOL_GROUPS.filter((group) => group.tools.some((name) => !BASIC_FILE_TOOLS.includes(name))), (group: ToolGroup) => {
          SectionHeader({ title: toolGroupTitle(group.id), caption: group.id === 'team-handoff' ?
            t('员工工具只用于团队子任务。关闭提交交接后，招募与继续团队也会停用。') : '' })
          GroupCard() {
            Column() {
              ForEach(group.tools, (name: string, index: number) => {
                if (index > 0) { RowDivider() }
                SwitchRow({ title: toolTitle(name), subtitle: name,
                  compId: 'custom-tool-' + name, isOn: !this.thread.disabledTools.includes(name),
                  disabled: !this.editable(),
                  onChange: (enabled: boolean) => { this.app.setToolEnabled(name, enabled); } })
              }, (name: string) => name)
            }
          }
        }, (group: ToolGroup) => group.id)
      }.width('100%').padding({ left: Space.md, right: Space.md, bottom: Space.lg })
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }
}
