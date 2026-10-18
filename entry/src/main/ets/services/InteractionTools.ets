import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { t } from '../model/I18n';
import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { parseDataView, parseForm, parsePlan } from '../model/RichArtifacts';
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
      }, ['steps']),
      this.definition('publish_data_view', '展示图表或表格，必须提供真实来源。最多200行20列；图表首列名称，其余为数值；瀑布图仅两列，第二列为变化量。禁止虚构数据来源。', {
        'title': { type: 'string', description: '标题', minLength: 1, maxLength: 200 },
        'kind': { type: 'string', description: '展示类型', enum: ['table', 'bar', 'line', 'waterfall', 'metrics'] },
        'source': { type: 'string', description: '数据来源', minLength: 1, maxLength: 2000 },
        'insight': { type: 'string', description: '数据说明', minLength: 1, maxLength: 4000 },
        'columns': { type: 'array', description: '列定义', minItems: 2, maxItems: 20,
          items: { type: 'object', description: '一列', properties: {
            'key': { type: 'string', description: '唯一列标识', minLength: 1, maxLength: 40 },
            'label': { type: 'string', description: '列名', minLength: 1, maxLength: 100 },
            'type': { type: 'string', description: '单元格类型', enum: ['string', 'number', 'boolean'] },
            'unit': { type: 'string', description: '单位', minLength: 1, maxLength: 40 }
          }, required: ['key', 'label', 'type'], additionalProperties: false } },
        'rows': { type: 'array', description: '各行按列顺序提供数值，类型须与 columns 对应', minItems: 1, maxItems: 200,
          items: { type: 'object', description: '一行', properties: {
            'values': { type: 'array', description: '按列顺序排列的单元格', minItems: 2, maxItems: 20,
              items: { description: '单元格值', anyOf: [
                { type: 'string', description: '文字', maxLength: 2000 },
                { type: 'number', description: '数值' }, { type: 'boolean', description: '布尔值' }
              ] } }
          }, required: ['values'], additionalProperties: false } }
      }, ['title', 'kind', 'source', 'columns', 'rows'])
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
    if (call.function.name === 'update_plan') { return JSON.stringify(parsePlan(data)); }
    return JSON.stringify(parseDataView(data));
  }
  private definition(name: string, description: string, properties: Record<string, ToolProperty>, required: string[]): ToolDefinition {
    const snippets: Record<string, string> = { 'request_user_input': '收集必要信息', 'update_plan': '展示任务进展', 'publish_data_view': '展示真实数据' };
    const guidelines: Record<string, string> = {
      'request_user_input': '缺少必要信息时用 request_user_input 集中提出简短问题，不重复确认已经明确的事项。',
      'update_plan': '复杂任务用 update_plan 展示并随实际进展更新步骤；简单任务不必建计划。',
      'publish_data_view': '用 publish_data_view 展示适合比较的真实数据，保留来源和单位；示例或估算必须标明，不能伪装成实测值。'
    };
    return { type: 'function', executionMode: 'sequential', promptSnippet: snippets[name], promptGuidelines: [guidelines[name]], function: { name: name, description: description, parameters: { type: 'object',
      properties: properties, required: required, additionalProperties: false } } };
  }
}
