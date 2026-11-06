import { ToolFailure } from './ToolFailure';

// Deliberately small JSON-schema subset shared by publication and every task result.
export interface PanelSchema {
  type: string; properties?: Record<string, PanelSchema>; required?: string[]; items?: PanelSchema;
  enum?: Object[]; minimum?: number; maximum?: number; additionalProperties?: boolean;
}
export interface PanelInput { type: string; default: string | number | boolean; options?: Object[]; }
export type PanelInputs = Record<string, string | number | boolean>;
export interface PanelCheck { action: string; selector?: string; value?: string; path?: string; expected?: Object | null; }
export interface PanelProbeOptions { width: number; height?: number; checks: PanelCheck[]; }
export function contractFailure(path: string, message: string): never {
  throw new ToolFailure('PANEL_CONTRACT_FAILED', path + ': ' + message, 'fix_card_and_validate_again', { path: path });
}
export function validatePanelSchema(schema: PanelSchema, path: string = '/dataSchema', depth: number = 0): void {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema) || depth > 8 ||
    Object.keys(schema).some((key: string) => !['type', 'properties', 'required', 'items', 'enum', 'minimum', 'maximum', 'additionalProperties'].includes(key)) ||
    !['object', 'array', 'string', 'number', 'integer', 'boolean', 'null'].includes(schema.type)) { contractFailure(path, 'Invalid schema (maximum depth 8)'); }
  if (schema.enum !== undefined && (!Array.isArray(schema.enum) || !schema.enum.length || schema.enum.length > 100)) { contractFailure(path, 'enum needs 1–100 values'); }
  for (const bound of [schema.minimum, schema.maximum]) { if (bound !== undefined && (!['number', 'integer'].includes(schema.type) || !Number.isFinite(bound))) { contractFailure(path, 'Invalid numeric bound'); } }
  if (schema.minimum !== undefined && schema.maximum !== undefined && schema.minimum > schema.maximum) { contractFailure(path, 'minimum exceeds maximum'); }
  if (schema.type === 'object') {
    if (schema.properties !== undefined && (!schema.properties || typeof schema.properties !== 'object' || Array.isArray(schema.properties) || Object.keys(schema.properties).length > 64)) { contractFailure(path, 'Invalid properties'); }
    if (schema.required !== undefined && (!Array.isArray(schema.required) || schema.required.some((key: string) => typeof key !== 'string' || !Object.keys(schema.properties || ({} as Record<string, PanelSchema>)).includes(key)))) { contractFailure(path, 'required must name declared properties'); }
    if (schema.additionalProperties !== undefined && typeof schema.additionalProperties !== 'boolean') { contractFailure(path, 'Invalid additionalProperties'); }
    for (const key of Object.keys(schema.properties || ({} as Record<string, PanelSchema>))) { validatePanelSchema(schema.properties![key], path + '/properties/' + key, depth + 1); }
  } else if (schema.properties !== undefined || schema.required !== undefined || schema.additionalProperties !== undefined) { contractFailure(path, 'Object fields require type object'); }
  if (schema.type === 'array') { if (!schema.items) { contractFailure(path, 'Array needs items'); } validatePanelSchema(schema.items!, path + '/items', depth + 1); }
  else if (schema.items !== undefined) { contractFailure(path, 'items requires type array'); }
}
export function checkPanelValue(schema: PanelSchema, value: Object | null | undefined, path: string = '/data'): void {
  const matches = schema.type === 'null' ? value === null : schema.type === 'array' ? Array.isArray(value) : schema.type === 'object' ?
    !!value && typeof value === 'object' && !Array.isArray(value) : schema.type === 'integer' ? Number.isSafeInteger(value) : typeof value === schema.type;
  if (!matches || typeof value === 'number' && !Number.isFinite(value)) { contractFailure(path, 'Expected ' + schema.type); }
  if (schema.enum && !schema.enum.some((item: Object) => JSON.stringify(item) === JSON.stringify(value))) { contractFailure(path, 'Value is outside enum'); }
  if (typeof value === 'number' && (schema.minimum !== undefined && value < schema.minimum || schema.maximum !== undefined && value > schema.maximum)) { contractFailure(path, 'Number outside bounds'); }
  if (schema.type === 'object') {
    const object = value as Record<string, Object>;
    for (const key of schema.required || []) { if (!Object.keys(object).includes(key)) { contractFailure(path + '/' + key, 'Required field is missing'); } }
    for (const key of Object.keys(object)) {
      if (schema.properties?.[key]) { checkPanelValue(schema.properties[key], object[key], path + '/' + key); }
      else if (schema.additionalProperties === false) { contractFailure(path + '/' + key, 'Unknown field'); }
    }
  } else if (schema.type === 'array') { (value as Object[]).forEach((item: Object, index: number) => checkPanelValue(schema.items!, item, path + '/' + index)); }
}
export function resolvePanelInputs(definitions: Record<string, PanelInput> = {}, supplied: PanelInputs = {}): PanelInputs {
  if (!definitions || Array.isArray(definitions) || typeof definitions !== 'object' || Object.keys(definitions).length > 16 ||
    !supplied || Array.isArray(supplied) || typeof supplied !== 'object') { contractFailure('/inputs', 'Expected up to 16 named inputs'); }
  const result: PanelInputs = {};
  for (const key of Object.keys(supplied)) { if (!Object.keys(definitions).includes(key)) { contractFailure('/inputs/' + key, 'Input is not declared'); } }
  for (const key of Object.keys(definitions)) {
    const input = definitions[key];
    if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key) || !input || Object.keys(input).some((field: string) => !['type', 'default', 'options'].includes(field)) ||
      !['string', 'number', 'boolean'].includes(input.type) || typeof input.default !== input.type ||
      input.options !== undefined && (!Array.isArray(input.options) || !input.options.length || input.options.length > 100 || input.options.some((item: Object) => typeof item !== input.type))) { contractFailure('/inputs/' + key, 'Invalid input definition'); }
    const value = supplied[key] === undefined ? input.default : supplied[key];
    if (typeof value !== input.type || typeof value === 'number' && !Number.isFinite(value) || typeof value === 'string' && value.length > 500 ||
      input.options && !input.options.includes(value)) { contractFailure('/inputs/' + key, 'Invalid input value'); }
    result[key] = value;
  }
  return result;
}
// Definition edits migrate saved preferences; explicit refresh requests remain strict.
export function reconcilePanelInputs(definitions: Record<string, PanelInput> = {}, saved: PanelInputs = {}): PanelInputs {
  const result = resolvePanelInputs(definitions);
  for (const key of Object.keys(result)) {
    const input = definitions[key], value = saved[key];
    if (typeof value === input.type && (!input.options || input.options.includes(value))) { result[key] = value; }
  }
  return resolvePanelInputs(definitions, result);
}
export function validatePanelChecks(checks: PanelCheck[]): void {
  if (!Array.isArray(checks) || checks.length > 12) { contractFailure('/checks', 'Expected up to 12 checks'); }
  checks.forEach((check: PanelCheck, index: number) => {
    const path = '/checks/' + index;
    if (!check || Object.keys(check).some((key: string) => !['action', 'selector', 'value', 'path', 'expected'].includes(key)) ||
      !['click', 'input', 'select', 'text', 'stored'].includes(check.action)) { contractFailure(path, 'Unknown check'); }
    if (check.action !== 'stored' && (typeof check.selector !== 'string' || !check.selector || check.selector.length > 300)) { contractFailure(path, 'Provide a CSS selector'); }
    if (['input', 'select', 'text'].includes(check.action) && (typeof check.value !== 'string' || check.value.length > 2000)) { contractFailure(path, 'Provide a value'); }
    if (check.action === 'stored' && (typeof check.path !== 'string' || !check.path.startsWith('/') || check.expected === undefined)) { contractFailure(path, 'Provide a JSON pointer and expected value'); }
  });
}
