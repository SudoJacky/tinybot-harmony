import { t } from './I18n';
import { AgentStep, ToolExecution, toolReceipts } from './Agent';
import { referencePreviewId } from './PreviewReferences';

export interface ProcessSummary { operations: number; failures: number; }
// tool < 0 marks the step's thinking; otherwise an index into the step's tools.
export interface ProcessItem { step: number; tool: number; }
// The answer reads as narration interleaved with process groups: everything between two narrations folds into one line.
export interface TimelineEntry { kind: string; key: string; step: number; items: ProcessItem[]; }

// Derive the turn's current phase from runtime events, never from a simulated step list.
export function turnPhase(status: string, steps: AgentStep[]): string {
  if (status !== 'generating') { return status; }
  const last = steps[steps.length - 1];
  if (!last) { return 'waiting'; }
  if (steps.some((step) => step.tools.some((tool) => tool.status === 'running' || tool.status === 'pending'))) { return 'tools'; }
  if (last.tools.length) { return 'waiting'; }
  if (last.content.trim()) { return 'answer'; }
  if ((last.reasoningContent || '').trim()) { return 'thinking'; }
  if (last.retries?.length) { return 'retry'; }
  return 'waiting';
}

export function workflowEntryState(entry: TimelineEntry, steps: AgentStep[], status: string): string {
  const tools = entry.items.filter((item) => item.tool >= 0).map((item) => steps[item.step]?.tools[item.tool]);
  if (tools.some((tool) => tool?.status === 'failed')) { return 'failed'; }
  if (tools.some((tool) => tool?.status === 'interrupted' || tool?.status === 'cancelled')) { return 'stopped'; }
  if (status === 'generating') {
    if (tools.some((tool) => tool?.status === 'running' || tool?.status === 'pending')) { return 'active'; }
    const last = steps[steps.length - 1];
    if (entry.kind === 'text' && entry.step === steps.length - 1 && !last.tools.length) { return 'active'; }
    if (entry.items.some((item) => item.tool < 0 && item.step === steps.length - 1) &&
      last.tools.length === 0 && !last.content.trim()) { return 'active'; }
  }
  // A stopped thought/answer must not acquire a success tick just because the turn ended.
  if ((status === 'stopped' || status === 'failed') &&
    (entry.step === steps.length - 1 || entry.items.some((item) => item.step === steps.length - 1))) { return status; }
  return 'complete';
}

export function summarizeProcess(steps: AgentStep[]): ProcessSummary {
  const result: ProcessSummary = { operations: 0, failures: 0 };
  for (const step of steps) {
    result.operations += step.tools.length;
    for (const tool of step.tools) {
      if (tool.status === 'failed') { result.failures++; }
    }
  }
  return result;
}

// Within a step the model thinks, then speaks, then calls tools, so a group holds a step's tools plus the next step's thinking.
export function buildTimeline(steps: AgentStep[]): TimelineEntry[] {
  const entries: TimelineEntry[] = [];
  let group: TimelineEntry | undefined = undefined;
  for (let index = 0; index < steps.length; index++) {
    const step = steps[index];
    if (step.steering) {
      group = undefined; entries.push({ kind: 'steering', key: 'steering-' + index, step: index, items: [] });
    }
    if (step.requestError) { continue; }
    const items: ProcessItem[] = [];
    if ((step.reasoningContent || '').trim().length > 0) { items.push({ step: index, tool: -1 }); }
    // A published surface creates a narration entry without joining every HTML snapshot.
    if (step.content.trim().length > 0 || toolReceipts(step.tools).some((tool) => tool.status === 'complete' &&
      tool.call.function.name === 'publish_preview' && (tool.previewContent || '').trim().length > 0 && !referencePreviewId(tool))) {
      group = appendItems(entries, group, items);
      group = undefined; entries.push({ kind: 'text', key: 'text-' + index, step: index, items: [] });
      items.splice(0);
    }
    for (let tool = 0; tool < step.tools.length; tool++) { items.push({ step: index, tool: tool }); }
    group = appendItems(entries, group, items);
  }
  return entries;
}

function appendItems(entries: TimelineEntry[], group: TimelineEntry | undefined, items: ProcessItem[]): TimelineEntry | undefined {
  if (!items.length) { return group; }
  let target = group;
  if (!target) {
    target = { kind: 'process', key: 'process-' + items[0].step + '-' + items[0].tool, step: items[0].step, items: [] };
    entries.push(target);
  }
  for (const item of items) { target.items.push(item); }
  return target;
}

// A finished answer that ends in narration folds its process behind the elapsed time.
export function foldsToAnswer(entries: TimelineEntry[]): boolean {
  return entries.length > 1 && entries[entries.length - 1].kind === 'text' && entries.some((entry) => entry.kind !== 'text');
}

export function persistentTool(tool: ToolExecution): boolean {
  return persistentTools([tool]).length > 0;
}

export function persistentTools(tools: ToolExecution[]): ToolExecution[] {
  return toolReceipts(tools).filter((tool) => (tool.call.function.name === 'publish_data_view' && tool.status === 'complete') ||
    (tool.call.function.name === 'request_user_input' && ['interrupted', 'cancelled'].includes(tool.status)));
}

interface ToolTarget { path?: string; url?: string; }

function toolCategory(name: string): string {
  if (['read_file', 'read_file_lines', 'read_attachment'].includes(name)) { return 'read'; }
  if (['write_file', 'edit_file'].includes(name)) { return 'edit'; }
  if (name.startsWith('team_')) { return 'team'; }
  if (name.startsWith('mcp_')) { return 'mcp'; }
  return ['find_files', 'list_files', 'search_file_content', 'read_web', 'read_skill', 'generate_image', 'update_plan', 'publish_data_view',
    'request_user_input'].includes(name) ? name : 'other';
}

function categoryLabel(category: string, count: number): string {
  switch (category) {
    case 'read': return t('读取了 {0} 个文件', [count]);
    case 'edit': return t('编辑了 {0} 个文件', [count]);
    case 'list_files': return t('浏览了 {0} 个目录', [count]);
    case 'find_files':
    case 'search_file_content': return t('搜索了 {0} 次', [count]);
    case 'read_web': return t('读取了 {0} 个网页', [count]);
    case 'read_skill': return t('读取了 {0} 个 Skill', [count]);
    case 'generate_image': return t('生成了 {0} 张图片', [count]);
    case 'update_plan': return t('更新了计划');
    case 'publish_data_view': return t('生成了 {0} 个图表', [count]);
    case 'request_user_input': return t('请你补充了信息');
    case 'team': return t('协调了团队');
    case 'mcp': return t('调用了 {0} 次远程工具', [count]);
    default: return t('调用了 {0} 个工具', [count]);
  }
}

// "编辑了 2 个文件，读取了 3 个文件": the same file touched twice counts once.
export function describeTools(tools: ToolExecution[]): string {
  const order: string[] = [];
  const targets = new Map<string, Set<string>>();
  for (const tool of tools) {
    const category = toolCategory(tool.call.function.name);
    let target = tool.call.id;
    try {
      const args = JSON.parse(tool.call.function.arguments) as ToolTarget;
      target = args.path || args.url || target;
    } catch (_) {}
    if (!targets.has(category)) { order.push(category); targets.set(category, new Set<string>()); }
    targets.get(category)?.add(target);
  }
  return order.map((category) => categoryLabel(category, targets.get(category)?.size || 0)).join(t('，'));
}

// Wall-clock span of the run, including the time spent in tools between model requests.
export function elapsedMs(steps: AgentStep[]): number {
  let start = Number.MAX_SAFE_INTEGER; let end = 0;
  for (const step of steps) {
    if (!step.usage) { continue; }
    start = Math.min(start, step.usage.startedAt); end = Math.max(end, step.usage.startedAt + step.usage.durationMs);
  }
  return end > start ? end - start : 0;
}

export function durationLabel(ms: number): string {
  const seconds = Math.max(1, Math.round(ms / 1000));
  return seconds < 60 ? t('{0} 秒', [seconds]) : t('{0} 分 {1} 秒', [Math.floor(seconds / 60), seconds % 60]);
}

// The latest line of streaming thought, trimmed from the left so the newest words stay visible.
export function thoughtTail(content: string, max: number = 48): string {
  const lines = content.split('\n').map((line) => line.trim()).filter((line) => line.length > 0);
  const last = lines.length ? lines[lines.length - 1] : '';
  return last.length > max ? '…' + last.slice(last.length - max) : last;
}
