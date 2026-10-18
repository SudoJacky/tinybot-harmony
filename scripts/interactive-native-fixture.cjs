// Reusable deterministic native example for protocol, session and real-device checks.
const state = { tab: '清单', people: 4, amount: 120, each: 30, buy: false, prepare: false, table: false, completed: 0 };
const records = [
  { op: 'begin', version: 1, title: '聚餐准备', state },
  { op: 'node', node: { id: 'mode', kind: 'segmented', text: '查看内容', bind: 'tab', options: ['清单', '对比'] } },
  { op: 'node', node: { id: 'people', kind: 'stepper', text: '参加人数', bind: 'people', min: 1, max: 12, step: 1, action: 'calculate' } },
  { op: 'node', node: { id: 'result', kind: 'heading', text: '每人 {{each}} 元' } },
  { op: 'node', node: { id: 'tasks', kind: 'card', visibleKey: 'tab', visibleValue: '清单' } },
  ...[['buy', '购买食材'], ['prepare', '备好配菜'], ['table', '摆好餐桌']].map(([id, text]) => ({ op: 'node', node: { id, kind: 'checkbox', parent: 'tasks', text, bind: id, action: 'calculate' } })),
  { op: 'node', node: { id: 'progress', kind: 'progress', parent: 'tasks', text: '已完成 {{completed}} / 3 项', bind: 'completed', min: 0, max: 3 } },
  { op: 'node', node: { id: 'comparison', kind: 'row', visibleKey: 'tab', visibleValue: '对比' } },
  { op: 'node', node: { id: 'standard', kind: 'card', parent: 'comparison' } },
  { op: 'node', node: { id: 'standardText', kind: 'text', parent: 'standard', text: '一起准备：分工采购，现场烹饪；适合有时间一起做饭的聚会。' } },
  { op: 'node', node: { id: 'simple', kind: 'card', parent: 'comparison' } },
  { op: 'node', node: { id: 'simpleText', kind: 'text', parent: 'simple', text: '提前备餐：先准备主要菜品，到场后只需摆盘；现场步骤较少。' } },
  { op: 'node', node: { id: 'copy', kind: 'button', text: '复制当前结果', action: 'copyResult' } },
  { op: 'node', node: { id: 'reset', kind: 'button', text: '重置', action: 'reset' } },
  { op: 'action', action: { id: 'calculate', kind: 'compute', code: 'input.each = Math.round(input.amount / input.people * 100) / 100; input.completed = Number(input.buy) + Number(input.prepare) + Number(input.table); return input;' } },
  { op: 'action', action: { id: 'copyResult', kind: 'copy', text: '聚餐：{{people}} 人，每人 {{each}} 元。\n准备进度：{{completed}} / 3 项。' } },
  { op: 'action', action: { id: 'reset', kind: 'reset' } },
  { op: 'end' }
];
const content = '调整人数、勾选准备事项，或切换查看方案。\n\n```tinybot-ui\n' + records.map(r => JSON.stringify(r)).join('\n') + '\n```\n\n数值是演示数据，复制不会调用模型。';
module.exports = { records, content };
