import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { SkillEditorViewModel } from '../viewmodel/SkillEditorViewModel';
import { SkillFile } from '../model/Skills';
import { readSkillImport } from '../services/SkillImport';
import { Btn, Font, Radius, Space, Styles } from '../common/Theme';
import { Banner, BottomBar, SectionHeader } from '../common/Widgets';

@Component
export struct SkillEditorPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink editor: SkillEditorViewModel;
  onSaved: () => void = () => {};
  @State private importing: boolean = false;
  @State private expandedPath: string = '';

  private get idle(): boolean {
    return !this.importing && !this.app.busy;
  }

  private async importText(reference: boolean): Promise<void> {
    if (this.importing || this.app.busy) { return; }
    this.importing = true;
    this.editor.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: picker.DocumentSelectOptions = { maxSelectNumber: 1 };
      if (!reference) { options.fileSuffixFilters = ['.md']; }
      const selected = await new picker.DocumentViewPicker(context).select(options);
      if (selected.length === 0) { return; }
      const text = await readSkillImport(selected[0]);
      if (reference) { this.editor.referenceText = text; }
      else { this.editor.document = text; }
    } catch (error) { this.editor.error = '导入失败：' + (error as Error).message; }
    finally { this.importing = false; }
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          Row() {
            SectionHeader({ title: 'SKILL.md', caption: '包含 name、description 和指令正文。' }).layoutWeight(1)
            Button(this.importing ? '导入中…' : '从文件导入').id('import-skill').attributeModifier(Btn.textSmall)
              .enabled(this.idle).onClick(() => this.importText(false))
          }.width('100%').alignItems(VerticalAlign.Bottom)
          TextArea({ text: this.editor.document, placeholder: '---\nname: my-skill\ndescription: …\n---\n\n指令正文' })
            .id('skill-document').attributeModifier(Styles.area).backgroundColor($r('app.color.surface'))
            .fontFamily('monospace').fontSize(13).height(280).maxLength(32000).enabled(this.idle)
            .onChange((value: string) => { this.editor.document = value; })
          SectionHeader({ title: `参考文件 · ${this.editor.files.length}`,
            caption: '使用与指令一致的相对路径。脚本仅作为文本保存，不会执行。' })
          Column() {
            ForEach(this.editor.files, (file: SkillFile, index: number) => {
              Column({ space: Space.sm }) {
                Row({ space: Space.sm }) {
                  SymbolGlyph($r('sys.symbol.doc_text')).fontSize(18).fontColor([$r('app.color.text_secondary')])
                  Text(file.path).fontSize(Font.small).maxLines(1).layoutWeight(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
                  SymbolGlyph(this.expandedPath === file.path ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                    .fontSize(14).fontColor([$r('app.color.text_tertiary')])
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([$r('app.color.text_secondary')])
                  }.width(32).height(32).backgroundColor(Color.Transparent).accessibilityText('移除')
                  .enabled(this.idle)
                  .onClick(() => { this.editor.files = this.editor.files.filter((item: SkillFile) => item.path !== file.path); })
                }.width('100%').height(44)
                .onClick(() => { this.expandedPath = this.expandedPath === file.path ? '' : file.path; })
                if (this.expandedPath === file.path) {
                  Scroll() {
                    Text(file.content).fontSize(Font.caption).lineHeight(18).copyOption(CopyOptions.LocalDevice)
                      .fontColor($r('app.color.text_primary')).width('100%')
                  }.constraintSize({ maxHeight: 200 }).width('100%').align(Alignment.TopStart).padding(Space.md)
                  .borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant')).margin({ bottom: Space.sm })
                }
                if (index < this.editor.files.length - 1) {
                  Divider().strokeWidth(0.5).color($r('app.color.divider'))
                }
              }.width('100%')
            }, (file: SkillFile) => file.path)
            if (this.editor.files.length > 0) {
              Divider().strokeWidth(0.5).color($r('app.color.divider'))
            }
            Column({ space: Space.sm }) {
              TextInput({ text: this.editor.referencePath, placeholder: '相对路径，例如 references/guide.md' })
                .id('skill-reference-path').attributeModifier(Styles.input).maxLength(256).enabled(this.idle)
                .onChange((value: string) => { this.editor.referencePath = value; })
              TextArea({ text: this.editor.referenceText, placeholder: '粘贴参考内容，或从文件导入' })
                .id('skill-reference-text').attributeModifier(Styles.area).height(110).maxLength(32000).enabled(this.idle)
                .onChange((value: string) => { this.editor.referenceText = value; })
              Row({ space: Space.sm }) {
                Button('从文件导入').attributeModifier(Btn.textSmall).enabled(this.idle).onClick(() => this.importText(true))
                Blank()
                Button('添加文件').attributeModifier(Btn.tonalSmall).enabled(this.idle)
                  .onClick(() => this.editor.addReference())
              }.width('100%')
            }.padding({ top: this.editor.files.length > 0 ? Space.md : 0 })
          }.padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
          Text('启用的 Skill 名称和简介会提供给模型；正文与参考内容只在读取时发送。最多保存 20 个 Skills。')
            .fontSize(Font.caption).lineHeight(18).fontColor($r('app.color.text_tertiary')).width('100%')
            .padding({ left: 4, right: 4, top: Space.md })
        }.padding({ left: Space.page, right: Space.page, bottom: Space.xl }).width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
      BottomBar() {
        Column({ space: Space.sm }) {
          if (this.editor.error.length > 0) { Banner({ text: this.editor.error, compId: 'skill-error' }) }
          Button('保存 Skill').id('save-skill').attributeModifier(Btn.primary).width('100%')
            .enabled(this.idle && this.app.saveError.length === 0)
            .onClick(async () => { if (await this.app.saveSkill()) { this.onSaved(); } })
        }
      }
    }.width('100%').height('100%')
  }
}
