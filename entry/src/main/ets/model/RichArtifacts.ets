import { t } from './I18n';
export interface PlanItem { step: string; status: string; }
export interface TaskPlan { explanation?: string; steps: PlanItem[]; }
export interface FormField { name: string; label: string; type: string; required?: boolean; options?: string[]; }
export interface InputForm { title: string; fields: FormField[]; }
export interface DataColumn { key: string; label: string; type: string; unit?: string; }
export interface DataRow { values: (string | number | boolean)[]; }
export interface DataView { title: string; kind: string; columns: DataColumn[]; rows: DataRow[]; source: string; insight?: string; }

function bounded(text: string, max: number): boolean { return typeof text === 'string' && text.trim().length > 0 && text.length <= max; }
export function parsePlan(text: string): TaskPlan {
  const plan = JSON.parse(text) as TaskPlan;
  if (!plan || (plan.explanation !== undefined && !bounded(plan.explanation, 2000)) || !Array.isArray(plan.steps) || plan.steps.length < 1 || plan.steps.length > 20 ||
    plan.steps.some((item) => !item || !bounded(item.step, 200) || !['pending', 'in_progress', 'completed'].includes(item.status)) ||
    plan.steps.filter((item) => item.status === 'in_progress').length !== (plan.steps.every((item) => item.status === 'completed') ? 0 : 1)) {
    throw new Error(t("计划需包含 1–20 个步骤，未完成时必须且只能有一个进行中步骤。"));
  }
  return plan;
}
export function parseForm(text: string): InputForm {
  const form = JSON.parse(text) as InputForm;
  if (!form || !bounded(form.title, 200) || !Array.isArray(form.fields) || form.fields.length < 1 || form.fields.length > 10) { throw new Error(t("提问需包含标题和 1–10 个字段。")); }
  const names = new Set<string>();
  for (const field of form.fields) {
    if (!field || !/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/.test(field.name) || ['constructor', 'prototype'].includes(field.name) || names.has(field.name) ||
      !bounded(field.label, 300) || !['text', 'number', 'select', 'multiselect'].includes(field.type) ||
      (field.required !== undefined && typeof field.required !== 'boolean')) { throw new Error(t("提问字段无效。")); }
    names.add(field.name);
    if (['select', 'multiselect'].includes(field.type) && (!Array.isArray(field.options) || field.options.length < 2 ||
      field.options.length > 10 || field.options.some((option) => !bounded(option, 100)) || new Set(field.options).size !== field.options.length)) { throw new Error(t("选项需包含 2–10 个不同的短文本。")); }
  }
  return form;
}
export function formResult(form: InputForm, values: string[]): string {
  const result: Record<string, string | string[]> = {};
  form.fields.forEach((field, index) => {
    const value = (values[index] || '').trim();
    if ((field.required && !value) || value.length > 2000) { throw new Error(t("请填写：") + field.label); }
    if (value && field.type === 'number' && !Number.isFinite(Number(value))) { throw new Error(field.label + t(" 需要数字。")); }
    if (value && field.type === 'select' && !(field.options || []).includes(value)) { throw new Error(t("选项无效。")); }
    const multiple = value ? value.split('\n') : [];
    if (field.type === 'multiselect' && multiple.some((item) => !(field.options || []).includes(item))) { throw new Error(t("多选值无效。")); }
    result[field.name] = field.type === 'multiselect' ? multiple : value;
  });
  return JSON.stringify({ status: 'submitted', values: result });
}
export function parseDataView(text: string): DataView {
  if (text.length > 160000) { throw new Error(t("图表数据过大。")); }
  const view = JSON.parse(text) as DataView;
  if (!view || !bounded(view.title, 200) || !bounded(view.source, 2000) || (view.insight !== undefined && !bounded(view.insight, 4000)) || !['table', 'bar', 'line', 'waterfall', 'metrics'].includes(view.kind) ||
    !Array.isArray(view.columns) || view.columns.length < 2 || view.columns.length > 20 || !Array.isArray(view.rows) || view.rows.length < 1 || view.rows.length > 200) { throw new Error(t("图表格式无效，需提供来源、2–20 列与 1–200 行。")); }
  const keys = new Set<string>();
  for (const column of view.columns) {
    if (!column || !bounded(column.key, 40) || keys.has(column.key) || !bounded(column.label, 100) || !['string', 'number', 'boolean'].includes(column.type) ||
      (column.unit !== undefined && !bounded(column.unit, 40))) { throw new Error(t("图表列无效。")); }
    keys.add(column.key);
  }
  for (const row of view.rows) {
    if (!row || !Array.isArray(row.values) || row.values.length !== view.columns.length) { throw new Error(t("图表行列不匹配。")); }
    row.values.forEach((value, index) => {
      if (typeof value !== view.columns[index].type || (typeof value === 'number' && !Number.isFinite(value)) ||
        (typeof value === 'string' && value.length > 2000)) { throw new Error(t("图表数值类型错误。")); }
    });
  }
  if (view.kind !== 'table' && (view.columns[0].type !== 'string' || view.columns.slice(1).some((item) => item.type !== 'number'))) { throw new Error(t("图表第一列为名称，其余列须为数字。")); }
  if (view.kind === 'waterfall' && view.columns.length !== 2) { throw new Error(t("瀑布图需要名称与变化值两列。")); }
  return view;
}
export function dataCsv(view: DataView): string {
  const quote = (value: string | number | boolean): string => {
    let text = String(value); if (typeof value === 'string' && /^[=+@\-\t\r]/.test(text)) { text = "'" + text; }
    return '"' + text.replace(/"/g, '""') + '"';
  };
  return [view.columns.map((item) => quote(item.label)).join(',')].concat(view.rows.map((row) => row.values.map(quote).join(','))).join('\r\n');
}
export function parseDelimited(text: string, delimiter: string): string[][] {
  const rows: string[][] = []; let row: string[] = []; let value = ''; let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') { if (quoted && text[i + 1] === '"') { value += '"'; i++; } else { quoted = !quoted; } }
    else if (!quoted && char === delimiter) { row.push(value); value = ''; }
    else if (!quoted && char === '\n') { row.push(value.replace(/\r$/, '')); rows.push(row); row = []; value = ''; }
    else { value += char; }
    if (rows.length > 200 || row.length > 50) { throw new Error(t("表格预览最多 200 行、50 列，请缩小文件或查看源码。")); }
  }
  if (quoted) { throw new Error(t("CSV 引号未闭合。")); }
  if (value || row.length) { row.push(value.replace(/\r$/, '')); rows.push(row); }
  if (rows.length > 200 || rows.some((item) => item.length > 50)) { throw new Error(t("表格预览最多 200 行、50 列，请缩小文件或查看源码。")); }
  return rows;
}
export function lineDiff(before: string, after: string): string {
  if (before === after) { return '没有变化'; }
  const left = before.split('\n'); const right = after.split('\n'); let start = 0; let end = 0;
  while (start < left.length && start < right.length && left[start] === right[start]) { start++; }
  while (end < left.length - start && end < right.length - start && left[left.length - 1 - end] === right[right.length - 1 - end]) { end++; }
  return '@@ 第 ' + (start + 1) + ' 行起 @@\n' + left.slice(start, left.length - end).map((line) => '- ' + line).join('\n') + '\n' + right.slice(start, right.length - end).map((line) => '+ ' + line).join('\n');
}
