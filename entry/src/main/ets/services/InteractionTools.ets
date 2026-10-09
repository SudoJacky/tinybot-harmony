import { t } from '../model/I18n';
import { ToolCall, ToolDefinition } from '../model/Agent';
import { parseDataView, parseForm, parsePlan } from '../model/RichArtifacts';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';
import { ToolApproval } from './ToolApproval';
interface Payload { data: string; }
export class InteractionTools implements AgentTools {
  private approval: ToolApproval;
  constructor(approval: ToolApproval) { this.approval = approval; }
  definitions(): ToolDefinition[] {
    return [
      this.definition('request_user_input', '在缺少必要信息时请求用户填写表单。data 是 JSON：{title,fields:[{name,label,type:"text|number|select|multiselect",required,options?:string[]}]}; 最多10字段。等待提交后继续。'),
      this.definition('update_plan', '展示并更新任务步骤。data 是 JSON：{steps:[{step,status:"pending|in_progress|completed"}]}; 未全部完成时恰好一个进行中步骤。每次提交完整计划。'),
      this.definition('publish_data_view', '展示图表或表格。data 是 JSON：{title,kind:"table|bar|line|waterfall|metrics",source,insight?,columns:[{key,label,type:"string|number|boolean",unit?}],rows:[{values:[值]}]}; 最多200行20列。图表首列名称，其余为数值；瀑布图仅两列，第二列为变化量。禁止虚构数据来源。')
    ];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check(); const args = JSON.parse(call.function.arguments) as Payload;
    if (!args || typeof args.data !== 'string') { throw new Error(t("需要 data JSON 字符串。")); }
    if (call.function.name === 'request_user_input') { return this.approval.ask(parseForm(args.data), cancellation); }
    if (call.function.name === 'update_plan') { return JSON.stringify(parsePlan(args.data)); }
    if (call.function.name === 'publish_data_view') { return JSON.stringify(parseDataView(args.data)); }
    throw new Error(t("未知交互工具。"));
  }
  private definition(name: string, description: string): ToolDefinition {
    const snippets: Record<string, string> = { 'request_user_input': '收集必要信息', 'update_plan': '展示任务进展', 'publish_data_view': '展示真实数据' };
    const guidelines: Record<string, string> = {
      'request_user_input': '缺少必要信息时用 request_user_input 集中提出简短问题，不重复确认已经明确的事项。',
      'update_plan': '复杂任务用 update_plan 展示并随实际进展更新步骤；简单任务不必建计划。',
      'publish_data_view': '用 publish_data_view 展示适合比较的真实数据，保留来源和单位；示例或估算必须标明，不能伪装成实测值。'
    };
    return { type: 'function', promptSnippet: snippets[name], promptGuidelines: [guidelines[name]], function: { name: name, description: description, parameters: { type: 'object',
      properties: { 'data': { type: 'string', description: '符合上述格式的 JSON 字符串' } }, required: ['data'], additionalProperties: false } } };
  }
}
