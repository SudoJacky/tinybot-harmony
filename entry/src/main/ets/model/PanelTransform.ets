export interface PanelExpression { path?: string; value?: Object | null; op?: string; args?: PanelExpression[]; fields?: Record<string, PanelExpression>; }
export interface PanelJavaScriptTransform { type: string; code: string; }
export type PanelSourceTransform = PanelExpression | PanelJavaScriptTransform;
export function validatePanelSourceTransform(transform: PanelSourceTransform): void {
  if (!transform || typeof transform !== 'object' || Array.isArray(transform)) { throw new Error('Invalid panel transform'); }
  const script = transform as PanelJavaScriptTransform;
  if (script.type !== undefined) {
    if (script.type !== 'javascript' || Object.keys(script).some((key: string) => !['type', 'code'].includes(key)) ||
      typeof script.code !== 'string' || !script.code.trim() || script.code.length > 64 * 1024) {
      throw new Error('JavaScript transform requires type:javascript and a nonempty code function body of up to 64 KiB');
    }
  } else { validatePanelTransform(transform as PanelExpression); }
}
interface TransformContext { response: Object | null; item: Object | null; index: number; }
interface TransformBudget { remaining: number; }
const ARITY: Record<string, number[]> = {
  'object': [0, 0], 'map': [2, 2], 'filter': [2, 2], 'slice': [3, 3],
  'add': [2, 16], 'subtract': [2, 2], 'multiply': [2, 16], 'divide': [2, 2], 'round': [1, 2],
  'sum': [1, 1], 'average': [1, 1], 'min': [1, 1], 'max': [1, 1], 'count': [1, 1],
  'number': [1, 1], 'string': [1, 1], 'concat': [1, 16],
  'eq': [2, 2], 'gt': [2, 2], 'gte': [2, 2], 'lt': [2, 2], 'lte': [2, 2]
};
export function pointerParts(path: string): string[] {
  if (typeof path !== 'string') { throw new Error('Expected a JSON Pointer'); }
  if (path === '') { return []; }
  if (!path.startsWith('/') || /~(?![01])/.test(path)) { throw new Error('Expected a JSON Pointer: ' + path); }
  const parts = path.slice(1).split('/').map((part: string) => part.replace(/~1/g, '/').replace(/~0/g, '~'));
  if (parts.some((part: string) => ['__proto__', 'prototype', 'constructor'].includes(part))) { throw new Error('Unsafe binding path'); }
  return parts;
}
export function jsonPointer(root: Object | null, path: string): Object | null {
  let value = root;
  for (const part of pointerParts(path)) {
    if (value === null || typeof value !== 'object' || !Object.keys(value).includes(part)) { throw new Error('Missing data at ' + path); }
    value = (value as Record<string, Object | null>)[part];
  }
  return value;
}
export function validatePanelTransform(expression: PanelExpression, depth: number = 0, budget: TransformBudget = { remaining: 128 }): void {
  if (--budget.remaining < 0 || depth > 10) { throw new Error('Transform exceeds 128 expressions or ten nesting levels'); }
  if (!expression || typeof expression !== 'object' || Array.isArray(expression) || Object.keys(expression).some((key: string) => !['path', 'value', 'op', 'args', 'fields'].includes(key))) { throw new Error('Invalid transform expression'); }
  if ([expression.path !== undefined, expression.value !== undefined, expression.op !== undefined].filter((set: boolean) => set).length !== 1) { throw new Error('Expression requires exactly one of path, value or op'); }
  if (expression.op === undefined) {
    if (expression.args !== undefined || expression.fields !== undefined) { throw new Error('Only operations accept args or fields'); }
    if (expression.path !== undefined) {
      if (typeof expression.path !== 'string' || !/^\/(response|item|index)(\/|$)/.test(expression.path)) { throw new Error('Transform paths start with /response, /item or /index'); }
      pointerParts(expression.path);
    }
    return;
  }
  if (typeof expression.op !== 'string' || !Object.keys(ARITY).includes(expression.op)) { throw new Error('Unknown transform operation'); }
  if (expression.op === 'object') {
    if (!expression.fields || typeof expression.fields !== 'object' || Array.isArray(expression.fields) || expression.args !== undefined || Object.keys(expression.fields).length > 32) { throw new Error('object requires up to 32 fields'); }
    for (const key of Object.keys(expression.fields)) {
      if (['__proto__', 'prototype', 'constructor'].includes(key)) { throw new Error('Unsafe transform field'); }
      validatePanelTransform(expression.fields[key], depth + 1, budget);
    }
  } else {
    const arity = ARITY[expression.op];
    if (expression.fields !== undefined || !Array.isArray(expression.args) || expression.args.length < arity[0] || expression.args.length > arity[1]) { throw new Error('Invalid arguments for ' + expression.op); }
    expression.args.forEach((arg: PanelExpression) => validatePanelTransform(arg, depth + 1, budget));
  }
}
function numeric(value: Object | null): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) { throw new Error('Transform requires finite numbers'); } return value;
}
function scalar(value: Object | null): string {
  if (!['string', 'number', 'boolean'].includes(typeof value) || value === null) { throw new Error('Transform requires scalar text'); } return String(value);
}
function array(value: Object | null): Object[] {
  if (!Array.isArray(value) || value.length > 1000) { throw new Error('Transform requires an array of up to 1000 items'); } return value as Object[];
}
function evaluate(expression: PanelExpression, context: TransformContext, budget: TransformBudget): Object | null {
  if (--budget.remaining < 0) { throw new Error('Transform exceeded 10000 evaluation steps'); }
  if (expression.path !== undefined) { return jsonPointer(context, expression.path); }
  if (expression.op === undefined) { return expression.value as Object | null; }
  if (expression.op === 'object') {
    const result: Record<string, Object | null> = {};
    let size = 2;
    for (const key of Object.keys(expression.fields!)) {
      const value = evaluate(expression.fields![key], context, budget); size += JSON.stringify(key).length + JSON.stringify(value).length + 2;
      if (size > 256 * 1024) { throw new Error('Transformed object exceeds 256 KiB'); } result[key] = value;
    }
    return result;
  }
  const args = expression.args!;
  const first = evaluate(args[0], context, budget);
  if (expression.op === 'map' || expression.op === 'filter') {
    const values = array(first), result: Object[] = []; let size = 2;
    values.forEach((item: Object, index: number) => {
      const next: TransformContext = { response: context.response, item: item, index: index };
      const value = evaluate(args[1], next, budget);
      if (expression.op === 'filter' && typeof value !== 'boolean') { throw new Error('filter requires a boolean predicate'); }
      if (expression.op === 'map' || value === true) {
        const output = expression.op === 'map' ? value : item; size += JSON.stringify(output).length + 1;
        if (size > 256 * 1024) { throw new Error('Transformed array exceeds 256 KiB'); } result.push(output as Object);
      }
    }); return result;
  }
  if (expression.op === 'slice') {
    const start = numeric(evaluate(args[1], context, budget)), end = numeric(evaluate(args[2], context, budget));
    if (!Number.isInteger(start) || !Number.isInteger(end)) { throw new Error('slice requires integer bounds'); } return array(first).slice(start, end);
  }
  if (expression.op === 'count') { return array(first).length; }
  if (expression.op === 'string') { return scalar(first); }
  if (expression.op === 'number') {
    if (typeof first !== 'number' && (typeof first !== 'string' || !first.trim())) { throw new Error('number requires a number or nonempty numeric string'); }
    return numeric(Number(first));
  }
  if (['sum', 'average', 'min', 'max'].includes(expression.op)) {
    const values = array(first).map((value: Object) => numeric(value));
    if (!values.length && expression.op !== 'sum') { throw new Error('Cannot aggregate an empty array'); }
    if (expression.op === 'min') { return Math.min(...values); } if (expression.op === 'max') { return Math.max(...values); }
    const sum = numeric(values.reduce((total: number, value: number) => total + value, 0)); return expression.op === 'sum' ? sum : sum / values.length;
  }
  const values: (Object | null)[] = [first];
  args.slice(1).forEach((arg: PanelExpression) => values.push(evaluate(arg, context, budget)));
  if (expression.op === 'concat') {
    const parts = values.map((value: Object | null) => scalar(value));
    if (parts.reduce((size: number, value: string) => size + value.length, 0) > 256 * 1024) { throw new Error('Transformed text exceeds 256 KiB'); } return parts.join('');
  }
  if (expression.op === 'eq') {
    if (values.some((value: Object | null) => value !== null && typeof value === 'object')) { throw new Error('eq compares scalar values'); } return first === values[1];
  }
  const numbers = values.map((value: Object | null) => numeric(value));
  switch (expression.op) {
    case 'gt': return numbers[0] > numbers[1]; case 'gte': return numbers[0] >= numbers[1];
    case 'lt': return numbers[0] < numbers[1]; case 'lte': return numbers[0] <= numbers[1];
    case 'add': return numeric(numbers.reduce((a: number, b: number) => a + b, 0));
    case 'subtract': return numeric(numbers[0] - numbers[1]);
    case 'multiply': return numeric(numbers.reduce((a: number, b: number) => a * b, 1));
    case 'divide': if (!numbers[1]) { throw new Error('Division by zero'); } return numeric(numbers[0] / numbers[1]);
    case 'round': {
      const places = numbers.length > 1 ? numbers[1] : 0;
      if (!Number.isInteger(places) || places < 0 || places > 6) { throw new Error('round decimals must be 0–6'); } return Number(numbers[0].toFixed(places));
    }
    default: throw new Error('Unknown transform operation');
  }
}
export function transformPanelData(response: Object | null, expression?: PanelExpression): Object {
  if (expression) { validatePanelTransform(expression); }
  const context: TransformContext = { response: response, item: null, index: 0 };
  const value = expression ? evaluate(expression, context, { remaining: 10000 }) : response;
  if (value === null || typeof value !== 'object') { throw new Error('Panel source must resolve to a JSON object or array'); }
  if (JSON.stringify(value).length > 256 * 1024) { throw new Error('Transformed data exceeds 256 KiB'); } return value;
}
