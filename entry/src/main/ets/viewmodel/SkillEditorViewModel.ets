import { t } from '../model/I18n';
import { MAX_SKILL_TEXT, SkillData, SkillFile, skillPath } from '../model/Skills';

@Observed
export class SkillEditorViewModel {
  originalName: string = '';
  document: string = '';
  files: SkillFile[] = [];
  referencePath: string = '';
  referenceText: string = '';
  error: string = '';

  reset(skill?: SkillData): void {
    this.originalName = skill?.name || '';
    this.document = skill?.document || '---\nname: my-skill\ndescription: 说明这个 Skill 的用途和适用场景\n---\n\n在这里填写工作步骤。\n';
    this.files = skill ? skill.files.map((file: SkillFile): SkillFile => ({ path: file.path, content: file.content })) : [];
    this.referencePath = '';
    this.referenceText = '';
    this.error = '';
  }

  addReference(): void {
    this.error = '';
    try {
      const path = skillPath(this.referencePath.trim());
      if (path === 'SKILL.md' || this.files.some((file: SkillFile) => file.path === path)) {
        throw new Error(t("路径已存在；请先移除旧参考文件，SKILL.md 请在上方编辑。"));
      }
      if (this.files.length >= 16 || this.referenceText.length > MAX_SKILL_TEXT || this.referenceText.includes('\u0000')) {
        throw new Error(t("最多添加 16 个参考文件，每个文件最多 32000 字符，且必须是文本。"));
      }
      this.files = this.files.concat([{ path: path, content: this.referenceText }]);
      this.referencePath = '';
      this.referenceText = '';
    } catch (error) { this.error = (error as Error).message; }
  }
}
