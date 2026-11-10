import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { SkillData, SkillSource, skillPath } from '../model/Skills';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { builtinSkillInfo } from '../model/BuiltinSkills';

interface SkillArguments { name: string; path?: string; offset?: number; limit?: number; }
interface SkillListing { name: string; description: string; enabled: boolean; manualOnly: boolean; source?: SkillSource; }

export class SkillTools implements AgentTools {
  private skills: SkillData[];
  private live?: () => SkillData[];
  private selected: string;
  private readResource?: (name: string, path: string) => Promise<string>;

  constructor(skills: SkillData[], selected: string = '', live?: () => SkillData[],
    readResource?: (name: string, path: string) => Promise<string>) {
    this.live = live; this.selected = selected;
    this.readResource = readResource;
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
        'path': { type: 'string', description: 'Skill 内相对路径，省略时为 SKILL.md。' },
        'offset': { type: 'integer', minimum: 0, description: 'Zero-based UTF-16 offset. Use the previous nextOffset to continue.' },
        'limit': { type: 'integer', minimum: 1, maximum: 16000, description: 'Maximum characters per page.' }
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
    if (call.function.name !== 'read_skill') { throw new ToolFailure('TOOL_UNAVAILABLE', t("不支持的 Skill 工具。"), 'check_available_tools'); }
    const args = parseToolArguments(call.function.arguments) as SkillArguments;
    if (!args || Array.isArray(args) || typeof args.name !== 'string' ||
      (args.path !== undefined && typeof args.path !== 'string') ||
      (args.offset !== undefined && (!Number.isSafeInteger(args.offset) || args.offset < 0)) ||
      (args.limit !== undefined && (!Number.isSafeInteger(args.limit) || args.limit < 1 || args.limit > 16000)) ||
      Object.keys(args).some((key: string) => !['name', 'path', 'offset', 'limit'].includes(key))) {
      throw new ToolFailure('INVALID_ARGUMENTS', t("read_skill 参数需要 name 和可选的 path。"), 'fix_arguments');
    }
    const skill = (this.live ? this.live() : this.skills).find((item: SkillData) => item.name === args.name &&
      item.enabled && (!item.manualOnly || item.name === this.selected));
    if (!skill) { throw new ToolFailure('TOOL_UNAVAILABLE', t("Skill 未启用或本轮不可用：") + args.name, 'check_available_tools'); }
    const path = skillPath(args.path === undefined ? 'SKILL.md' : args.path);
    const resources = builtinSkillInfo(skill)?.resources || [];
    const bundled = resources.includes(path);
    let content = path === 'SKILL.md' ? skill.document : skill.files.find((file) => file.path === path)?.content;
    if (bundled) {
      if (!this.readResource) { throw new Error('Bundled Skill resource reader unavailable'); }
      content = await this.readResource(skill.name, path);
      cancellation.check();
    }
    if (content === undefined) { throw new ToolFailure('NOT_FOUND', t("Skill 参考文件尚未导入：") + path, 'check_resource'); }
    const paged = bundled || args.offset !== undefined || args.limit !== undefined;
    const offset = args.offset ?? 0;
    const end = paged ? Math.min(offset + (args.limit ?? 12000), content.length) : content.length;
    return JSON.stringify({ name: skill.name, path: path, content: content.slice(offset, end),
      files: skill.files.map((file) => file.path).concat(resources), totalChars: paged ? content.length : undefined,
      nextOffset: end < content.length ? end : undefined, kind: path === 'SKILL.md' ? 'skill_instructions' : 'reference_data' });
  }
}
