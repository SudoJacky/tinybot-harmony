import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { SkillData, skillPath } from '../model/Skills';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

interface SkillArguments { name: string; path?: string; }

export class SkillTools implements AgentTools {
  private skills: SkillData[];

  constructor(skills: SkillData[], selected: string = '') {
    // Freeze documents as well as visibility for the entire run.
    this.skills = JSON.parse(JSON.stringify(skills.filter((skill: SkillData) =>
      skill.enabled && (!skill.manualOnly || skill.name === selected)))) as SkillData[];
  }

  definitions(): ToolDefinition[] {
    if (this.skills.length === 0) { return []; }
    return [{ type: 'function', function: {
      name: 'read_skill', description: '读取已启用 Skill 的指令或随附参考文件。先读取 SKILL.md；结果包含可读取的参考文件路径。只读取资料，不执行脚本。',
      parameters: { type: 'object', properties: {
        'name': { type: 'string', description: 'Skills 目录中的准确名称。' },
        'path': { type: 'string', description: 'Skill 内相对路径，省略时为 SKILL.md。' }
      }, required: ['name'], additionalProperties: false }
    } }];
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (call.function.name !== 'read_skill') { throw new Error(t("不支持的 Skill 工具。")); }
    const args = JSON.parse(call.function.arguments) as SkillArguments;
    if (!args || Array.isArray(args) || typeof args.name !== 'string' ||
      (args.path !== undefined && typeof args.path !== 'string') ||
      Object.keys(args).some((key: string) => key !== 'name' && key !== 'path')) {
      throw new Error(t("read_skill 参数需要 name 和可选的 path。"));
    }
    const skill = this.skills.find((item: SkillData) => item.name === args.name);
    if (!skill) { throw new Error(t("Skill 未启用或本轮不可用：") + args.name); }
    const path = skillPath(args.path === undefined ? 'SKILL.md' : args.path);
    const content = path === 'SKILL.md' ? skill.document : skill.files.find((file) => file.path === path)?.content;
    if (content === undefined) { throw new Error(t("Skill 参考文件尚未导入：") + path); }
    return JSON.stringify({ name: skill.name, path: path, content: content,
      files: skill.files.map((file) => file.path), kind: path === 'SKILL.md' ? 'skill_instructions' : 'reference_data' });
  }
}
