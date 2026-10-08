// Deterministic client fixture: calculator, conditional content, chart and vector scene.
const state = { amount: 120, people: 3, each: 40, details: true, chart: '', scene: '' };
const chart = (amount, people) => JSON.stringify({ title: 'Split', kind: 'bar', source: 'Current inputs', columns: [
  { key: 'name', label: 'Item', type: 'string' }, { key: 'amount', label: 'Amount', type: 'number' }
], rows: [{ values: ['Total', amount] }, { values: ['Each', Math.round(amount / people * 100) / 100] }] });
const scene = (people) => JSON.stringify({ width: 400, height: 180, shapes: Array.from({ length: people }, (_, index) => ({
  id: 'person' + index, kind: 'circle', x: 40 + (index % 6) * 60, y: 50 + Math.floor(index / 6) * 80, radius: 20, color: '#397acb', text: 'Person ' + (index + 1)
})) });
state.chart = chart(state.amount, state.people); state.scene = scene(state.people);
const compute = 'input.each = Math.round(input.amount / input.people * 100) / 100; input.chart = (' + chart.toString() + ')(input.amount,input.people); input.scene = (' + scene.toString() + ')(input.people); return input;';
const records = [
  { op: 'begin', version: 1, title: '一起分账 / Split the bill', state },
  { op: 'node', node: { id: 'people', kind: 'slider', text: '人数 / People', bind: 'people', min: 1, max: 12, step: 1, action: 'calculate' } },
  { op: 'node', node: { id: 'amount', kind: 'number', text: '总金额 / Total', bind: 'amount', min: 0, max: 100000, action: 'calculate' } },
  { op: 'node', node: { id: 'answer', kind: 'heading', text: '每人 / Each: {{each}}' } },
  { op: 'node', node: { id: 'details', kind: 'toggle', text: '显示图解 / Show visuals', bind: 'details' } },
  { op: 'node', node: { id: 'plot', kind: 'data', bind: 'chart', visibleKey: 'details', visibleValue: true } },
  { op: 'node', node: { id: 'scene', kind: 'scene', bind: 'scene', visibleKey: 'details', visibleValue: true } },
  { op: 'node', node: { id: 'buttons', kind: 'row' } },
  { op: 'node', node: { id: 'reset', kind: 'button', parent: 'buttons', text: '重置 / Reset', action: 'reset' } },
  { op: 'node', node: { id: 'send', kind: 'button', parent: 'buttons', text: '发送并继续 / Send', action: 'send' } },
  { op: 'action', action: { id: 'calculate', kind: 'compute', code: compute } },
  { op: 'action', action: { id: 'reset', kind: 'reset' } },
  { op: 'action', action: { id: 'send', kind: 'submit', prompt: 'Explain the current bill split.' } },
  { op: 'end' }
];
const content = '这个界面由本地固定样例生成，拖动人数即可在手机上重新计算。\n\n```tinybot-ui\n' + records.map(r => JSON.stringify(r)).join('\n') + '\n```\n\n修改后可重新打开聊天检查状态是否保留。';
module.exports = { content, records };
