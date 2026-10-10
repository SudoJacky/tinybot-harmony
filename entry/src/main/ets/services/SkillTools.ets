import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { SkillData, SkillSource, skillPath } from '../model/Skills';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

interface SkillArguments { name: string; path?: string; }
interface SkillListing { name: string; description: string; enabled: boolean; manualOnly: boolean; source?: SkillSource; }

export class SkillTools implements AgentTools {
  private skills: SkillData[];
  private live?: () => SkillData[];
  private selected: string;

  constructor(skills: SkillData[], selected: string = '', live?: () => SkillData[]) {
    this.live = live; this.selected = selected;
    // Freeze documents as well as visibility for the entire run.
    this.skills = JSON.parse(JSON.stringify(skills.filter((skill: SkillData) =>
      skill.enabled && (!skill.manualOnly || skill.name === selected)))) as SkillData[];
  }

  definitions(): ToolDefinition[] {
    if (!this.live && this.skills.length === 0) { return []; }
    const definitions: ToolDefinition[] = [{ type: 'function', executionMode: 'sequential', promptSnippet: '读取 Skill 正文与参考文件',
      promptGuidelines: ['任务匹配 Skill 时，先用 read_skill 读取正文；用户消息已包含该 Skill 正文时直接使用，参考文件按需读取。Skill 不授予新工具或权限。'], function: {
      name: 'read_skill', description: '读取已启用 Skill 的指令或随附参考文件。先读取 SKILL.md；结果包含可读取的参考文件路径。只读取资料，不执行脚本。',
      parameters: { type: 'object', properties: {
        'name': { type: 'string', description: 'Skills 目录中的准确名称。' },
        'path': { type: 'string', description: 'Skill 内相对路径，省略时为 SKILL.md。' }
      }, required: ['name'], additionalProperties: false }
    } }];
    if (this.live) { definitions.push({ type: 'function', executionMode: 'sequential', function: {
      name: 'list_skills', description: '查看最新 Skills 名称、用途、启用状态和安装来源。安装或修改后无需重启。manualOnly 的 Skill 只能由用户通过 /skill:name 显式选择使用。',
      parameters: { type: 'object', properties: {}, required: [], additionalProperties: false }
    } }); }
    return definitions;
  }

  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (call.function.name === 'list_skills') {
      return JSON.stringify((this.live ? this.live() : this.skills).map((item): SkillListing => { return {
        name: item.name, description: item.description, enabled: item.enabled, manualOnly: item.manualOnly, source: item.source
      }; }));
    }
    if (call.function.name !== 'read_skill') { throw new Error(t("不支持的 Skill 工具。")); }
    const args = JSON.parse(call.function.arguments) as SkillArguments;
    if (!args || Array.isArray(args) || typeof args.name !== 'string' ||
      (args.path !== undefined && typeof args.path !== 'string') ||
      Object.keys(args).some((key: string) => key !== 'name' && key !== 'path')) {
      throw new Error(t("read_skill 参数需要 name 和可选的 path。"));
    }
    const skill = (this.live ? this.live() : this.skills).find((item: SkillData) => item.name === args.name &&
      item.enabled && (!item.manualOnly || item.name === this.selected));
    if (!skill) { throw new Error(t("Skill 未启用或本轮不可用：") + args.name); }
    const path = skillPath(args.path === undefined ? 'SKILL.md' : args.path);
    const content = path === 'SKILL.md' ? skill.document : skill.files.find((file) => file.path === path)?.content;
    if (content === undefined) { throw new Error(t("Skill 参考文件尚未导入：") + path); }
    return JSON.stringify({ name: skill.name, path: path, content: content,
      files: skill.files.map((file) => file.path), kind: path === 'SKILL.md' ? 'skill_instructions' : 'reference_data' });
  }
}
