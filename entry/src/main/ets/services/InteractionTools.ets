import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { parseForm, parsePlan } from '../model/RichArtifacts';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { ToolApproval } from './ToolApproval';
export class InteractionTools implements AgentTools {
  private approval: ToolApproval;
  constructor(approval: ToolApproval) { this.approval = approval; }
  definitions(): ToolDefinition[] {
    return [
      this.definition('request_user_input', '在缺少必要信息时请求用户填写表单。提供标题和 1–10 个字段；选择字段需提供 2–10 个不同选项。等待提交后继续。', {
        'title': { type: 'string', description: '表单标题', minLength: 1, maxLength: 200 },
        'fields': { type: 'array', description: '需要用户填写的字段', minItems: 1, maxItems: 10,
          items: { type: 'object', description: '一个表单字段', properties: {
            'name': { type: 'string', description: '唯一字段名，字母开头，仅含字母、数字、下划线', minLength: 1, maxLength: 40 },
            'label': { type: 'string', description: '显示名称', minLength: 1, maxLength: 300 },
            'type': { type: 'string', description: '字段类型', enum: ['text', 'number', 'select', 'multiselect'] },
            'required': { type: 'boolean', description: '是否必填' },
            'options': { type: 'array', description: '单选或多选字段的选项', minItems: 2, maxItems: 10,
              items: { type: 'string', description: '一个选项', minLength: 1, maxLength: 100 } }
          }, required: ['name', 'label', 'type'], additionalProperties: false } }
      }, ['title', 'fields']),
      this.definition('update_plan', '展示并更新任务步骤。未全部完成时恰好一个进行中步骤。每次提交完整计划。', {
        'explanation': { type: 'string', description: '计划说明', minLength: 1, maxLength: 2000 },
        'steps': { type: 'array', description: '完整任务步骤', minItems: 1, maxItems: 20,
          items: { type: 'object', description: '一个任务步骤', properties: {
            'step': { type: 'string', description: '步骤内容', minLength: 1, maxLength: 200 },
            'status': { type: 'string', description: '步骤状态', enum: ['pending', 'in_progress', 'completed'] }
          }, required: ['step', 'status'], additionalProperties: false } }
      }, ['steps'])
    ];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const definition = this.definitions().find((tool) => tool.function.name === call.function.name);
    if (!definition) { throw new ToolFailure('TOOL_UNAVAILABLE', t("未知交互工具。"), 'check_available_tools'); }
    const args = parseToolArguments(call.function.arguments);
    if (!args || typeof args !== 'object' || Array.isArray(args) ||
      Object.keys(args).some((key) => !Object.keys(definition.function.parameters.properties).includes(key))) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected native tool parameter fields.', 'fix_arguments');
    }
    // Reuse persisted artifact validators; encoding belongs at this local boundary.
    const data = JSON.stringify(args);
    if (call.function.name === 'request_user_input') { return this.approval.ask(parseForm(data), cancellation); }
    return JSON.stringify(parsePlan(data));
  }
  private definition(name: string, description: string, properties: Record<string, ToolProperty>, required: string[]): ToolDefinition {
    const snippets: Record<string, string> = { 'request_user_input': '收集必要信息', 'update_plan': '展示任务进展' };
    const guidelines: Record<string, string> = {
      'request_user_input': '缺少必要信息时用 request_user_input 集中提出简短问题，不重复确认已经明确的事项。',
      'update_plan': '复杂任务用 update_plan 展示并随实际进展更新步骤；简单任务不必建计划。'
    };
    return { type: 'function', executionMode: 'sequential', promptSnippet: snippets[name], promptGuidelines: [guidelines[name]], function: { name: name, description: description, parameters: { type: 'object',
      properties: properties, required: required, additionalProperties: false } } };
  }
}
