import { ToolCall, ToolDefinition } from '../model/Agent';
import { MemoryOperation, parseMemoryOperations } from '../model/MemoryMaintenance';
import { AgentTools } from './AgentLoop';
import { Cancellation } from './Cancellation';

interface MemoryArguments { operations: string; }

export class MemoryTools implements AgentTools {
  private apply: (operations: MemoryOperation[], cancellation: Cancellation) => Promise<string>;
  constructor(apply: (operations: MemoryOperation[], cancellation: Cancellation) => Promise<string>) { this.apply = apply; }
  definitions(): ToolDefinition[] {
    return [{ type: 'function', executionMode: 'sequential', promptSnippet: '维护长期记忆',
      promptGuidelines: ['用户明确要求记住、纠正或忘记长期事实时，调用 memory 确认保存结果，不能只口头承诺。' +
        '仅保存用户明确表达的稳定事实，助手猜测、临时进度、密码和密钥不得保存。任务方法归入 Skills。'],
      function: { name: 'memory', description: '维护本地长期记忆；operations 是 JSON 数组，最多5项。' +
        'add:{action:"add",scope:"global|thread",content:"事实"}；update:{action:"update",id:"记忆ID",content:"完整新事实"}；' +
        'remove:{action:"remove",id:"记忆ID"}。更新和删除仅允许 automatic:true 的记忆；不修改手动记忆。' +
        '当前项目约定使用 thread，跨对话稳定偏好使用 global。每条最多500字符，库最多100条/16000字符。' +
        '已有矛盾条目应更新，重复不要新增；删除只用于用户明确要求忘记的内容。一次批量修改按最终容量校验，失败不写入。' +
        'operations:"[]" 可查看最新记忆及容量。自动修改不会改变当前会话的固定背景快照，以本工具的最新回执为准。',
      parameters: { type: 'object', properties: { 'operations': { type: 'string', description: '记忆操作的 JSON 数组字符串；[] 读取当前记忆。' } },
        required: ['operations'], additionalProperties: false } } }];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const args = JSON.parse(call.function.arguments) as MemoryArguments;
    if (!args || typeof args.operations !== 'string') { throw new Error('Memory requires an operations JSON string.'); }
    return this.apply(parseMemoryOperations(args.operations), cancellation);
  }
}
