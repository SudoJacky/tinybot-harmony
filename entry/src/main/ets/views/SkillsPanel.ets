import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { SkillData } from '../model/Skills';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { Banner, BottomBar } from '../common/Widgets';

@Component
export struct SkillsPanel {
  @ObjectLink app: ChatViewModel;
  onEdit: (name: string) => void = () => {};
  onUse: () => void = () => {};

  private locked(): boolean {
    return this.app.busy || this.app.saveError.length > 0;
  }

  private confirmDelete(skill: SkillData): void {
    this.getUIContext().showAlertDialog({ title: t("删除 Skill？"), message: skill.name + t("\n已保存的对话记录会保留。"),
      primaryButton: { value: t("取消"), action: () => {} },
      secondaryButton: { value: t("删除"), fontColor: $r('app.color.danger'),
        action: () => { this.app.changeSkill(skill.name, true); } } });
  }

  @Builder
  skillCard(skill: SkillData) {
    Column({ space: 10 }) {
      Row({ space: Space.md }) {
        Column({ space: 3 }) {
          Text(skill.name).fontSize(Font.title).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          Text(t("{0} 个参考文件{1}", [skill.files.length, skill.manualOnly ? t(' · 仅手动调用') : '']))
            .fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: skill.enabled }).id('toggle-skill-' + skill.name)
          .selectedColor($r('app.color.accent')).enabled(!this.locked())
          .onChange((value: boolean) => { if (value !== skill.enabled) { this.app.changeSkill(skill.name); } })
      }.width('100%')
      if (skill.description.length > 0) {
        Text(skill.description).fontSize(Font.small).lineHeight(21).maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary')).width('100%')
      }
      Row({ space: Space.sm }) {
        Button(t("在对话中使用")).attributeModifier(Btn.tonalSmall)
          .enabled(skill.enabled && !this.app.busy && !this.app.active.archived)
          .onClick(() => { if (this.app.useSkill(skill.name)) { this.onUse(); } })
        Button(t("编辑")).attributeModifier(Btn.plainSmall).enabled(!this.locked()).onClick(() => this.onEdit(skill.name))
        Blank()
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([$r('app.color.danger')])
        }.width(36).height(36).backgroundColor(Color.Transparent).accessibilityText(t("删除"))
        .enabled(!this.locked()).onClick(() => this.confirmDelete(skill))
      }.width('100%')
    }.padding(Space.lg).borderRadius(Radius.lg).width('100%').backgroundColor($r('app.color.surface'))
    .opacity(skill.enabled ? 1 : 0.75)
  }

  build() {
    Column() {
      List({ space: Space.md }) {
        if (this.app.extensions.skills.length === 0) {
          ListItem() {
            Column({ space: Space.md }) {
              SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(40).fontColor([$r('app.color.text_tertiary')])
              Text(t("还没有 Skills")).fontSize(15).fontColor($r('app.color.text_secondary'))
              Text(t("导入或粘贴 SKILL.md 来教会 Tinybot 新技能。")).fontSize(13).fontColor($r('app.color.text_tertiary'))
            }.width('100%').padding({ top: 64, bottom: 64 })
          }
        }
        ForEach(this.app.extensions.skills, (skill: SkillData) => {
          ListItem() { this.skillCard(skill) }
        }, (skill: SkillData) => JSON.stringify(skill))
        if (this.app.error.length > 0) {
          ListItem() { Banner({ text: this.app.error }) }
        }
      }.layoutWeight(1).width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm }).scrollBar(BarState.Off)
      .contentEndOffset(Space.lg).edgeEffect(EdgeEffect.Spring)
      BottomBar() {
        Button(t("添加 Skill")).id('add-skill').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.locked()).onClick(() => this.onEdit(''))
      }
    }.width('100%').height('100%')
  }
}
