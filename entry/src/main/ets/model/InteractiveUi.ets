import { parseDataView } from './RichArtifacts';
import { parseUiScene } from './UiScene';
// Platform-independent versioned JSONL UI protocol. Only complete records are applied.
export type UiValue = string | number | boolean;
export type UiValues = Record<string, UiValue>;
export interface UiSavedState { key: string; values: UiValues; }
export interface UiAction { id: string; kind: string; code?: string; prompt?: string; values?: UiValues; }
export interface UiNode {
  id: string; kind: string; parent?: string; text?: string; bind?: string; action?: string;
  options?: string[]; min?: number; max?: number; step?: number;
  visibleKey?: string; visibleValue?: UiValue; source?: string; data?: string;
}
export interface UiRecord { op: string; version?: number; title?: string; state?: UiValues; node?: UiNode; action?: UiAction; }
export interface UiDocument { version: number; title: string; initial: UiValues; nodes: UiNode[]; actions: UiAction[]; complete: boolean; }
export interface UiPart { kind: string; key: string; content: string; closed: boolean; }
const CONTAINERS: string[] = ['column', 'row', 'card'];
const INPUTS: string[] = ['input', 'number', 'select', 'toggle', 'slider'];
const KINDS: string[] = CONTAINERS.concat(INPUTS, ['text', 'heading', 'markdown', 'button', 'progress', 'divider', 'image', 'data', 'scene']);
function fail(detail: string): never { throw new Error('Interactive UI: ' + detail); }
export function uiIdentifier(value: string): boolean {
  return typeof value === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(value) && !['constructor', 'prototype', '__proto__'].includes(value);
}
function text(value: string | undefined, max: number, required: boolean = false): void {
  if (value === undefined && !required) { return; }
  if (typeof value !== 'string' || value.length > max || (required && !value.trim())) { fail('invalid text'); }
}
function fields(value: Object, allowed: string[]): void {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some((key) => !allowed.includes(key))) { fail('unknown or malformed fields'); }
}
export function validateUiValues(values: UiValues): void {
  if (!values || typeof values !== 'object' || Array.isArray(values) || Object.keys(values).length > 64 || JSON.stringify(values).length > 12000) { fail('state exceeds 64 fields / 12,000 characters'); }
  for (const key of Object.keys(values)) {
    const value = values[key];
    if (!uiIdentifier(key) || !['string', 'number', 'boolean'].includes(typeof value) || (typeof value === 'number' && !Number.isFinite(value))) { fail('invalid state field ' + key); }
  }
}
export function copyUiValues(values: UiValues): UiValues { return JSON.parse(JSON.stringify(values)) as UiValues; }
export function validateUiStates(states: UiSavedState[]): void {
  if (!Array.isArray(states) || states.length > 32) { fail('too many saved surfaces'); }
  const keys = new Set<string>();
  for (const item of states) {
    if (!item || typeof item.key !== 'string' || !/^\d+:\d+$/.test(item.key) || keys.has(item.key)) { fail('invalid saved surface key'); }
    keys.add(item.key); validateUiValues(item.values);
  }
}
export function validateUiState(document: UiDocument, values: UiValues): void {
  validateUiValues(values);
  const keys = Object.keys(document.initial);
  if (keys.length !== Object.keys(values).length || keys.some((key) => typeof values[key] !== typeof document.initial[key])) { fail('state must retain declared keys and types'); }
  for (const node of document.nodes) {
    if (node.kind === 'data') { parseDataView(node.bind ? String(values[node.bind]) : node.data || ''); }
    if (node.kind === 'scene') {
      const scene = parseUiScene(node.bind ? String(values[node.bind]) : node.data || '');
      for (const shape of scene.shapes) {
        if (shape.action && !document.actions.some((action) => action.id === shape.action)) { fail(node.id + ': unknown scene action'); }
      }
    }
    if (!node.bind) { continue; }
    const value = values[node.bind];
    if (node.kind === 'select' && !node.options?.includes(String(value))) { fail(node.id + ': invalid selection'); }
    if (['slider', 'number', 'progress'].includes(node.kind) && ((node.min !== undefined && Number(value) < node.min) || (node.max !== undefined && Number(value) > node.max))) { fail(node.id + ': value outside range'); }
  }
}
export function uiText(template: string, values: UiValues): string {
  return template.replace(/\{\{([A-Za-z][A-Za-z0-9_-]*)\}\}/g, (_match: string, key: string) => {
    if (!Object.keys(values).includes(key)) { return fail('unknown binding ' + key); }
    return String(values[key]);
  });
}
export function uiNodeText(node: UiNode, values: UiValues): string {
  return node.bind && !INPUTS.includes(node.kind) ? String(values[node.bind]) : uiText(node.text || '', values);
}
export class UiCompiler {
  document: UiDocument = { version: 1, title: '', initial: {}, nodes: [], actions: [], complete: false };
  error: string = '';
  private source: string = '';
  private offset: number = 0;
  private records: number = 0;
  private begun: boolean = false;
  update(source: string, final: boolean): UiDocument {
    if (!source.startsWith(this.source)) { fail('stream rewrote published prefix'); }
    this.source = source;
    if (this.error) { throw new Error(this.error); }
    try {
      if (source.length > 96000) { fail('surface exceeds 96,000 characters'); }
      let end = source.indexOf('\n', this.offset);
      while (end >= 0) { this.line(source.slice(this.offset, end)); this.offset = end + 1; end = source.indexOf('\n', this.offset); }
      if (final && this.offset < source.length) { this.line(source.slice(this.offset)); this.offset = source.length; }
      if (final && !this.document.complete) { fail('incomplete surface: expected end record'); }
      return this.document;
    } catch (error) { this.error = (error as Error).message; throw error as Error; }
  }
  private line(line: string): void {
    if (!line.trim()) { return; }
    if (++this.records > 512) { fail('too many records'); }
    if (this.document.complete) { fail('record after end'); }
    const record = JSON.parse(line) as UiRecord;
    if (!record || typeof record !== 'object') { fail('invalid record'); }
    if (!this.begun) {
      fields(record, ['op', 'version', 'title', 'state']);
      if (record.op !== 'begin' || record.version !== 1) { fail('expected begin with version 1'); }
      text(record.title, 160, true); validateUiValues(record.state as UiValues);
      this.document.title = record.title as string; this.document.initial = copyUiValues(record.state as UiValues); this.begun = true; return;
    }
    if (record.op === 'node') { fields(record, ['op', 'node']); this.node(record.node as UiNode); }
    else if (record.op === 'action') { fields(record, ['op', 'action']); this.action(record.action as UiAction); }
    else if (record.op === 'end') {
      fields(record, ['op']);
      if (!this.document.nodes.length) { fail('empty surface'); }
      for (const node of this.document.nodes) {
        if (node.action) {
          const action = this.document.actions.find((item) => item.id === node.action);
          if (!action || (node.kind !== 'button' && action.kind === 'submit')) { fail(node.id + ': invalid action reference'); }
        }
      }
      validateUiState(this.document, this.document.initial); this.document.complete = true;
    } else { fail('unknown operation'); }
  }
  private node(node: UiNode): void {
    fields(node, ['id', 'kind', 'parent', 'text', 'bind', 'action', 'options', 'min', 'max', 'step', 'visibleKey', 'visibleValue', 'source', 'data']);
    if (!uiIdentifier(node.id) || !KINDS.includes(node.kind)) { fail('invalid node id or kind'); }
    text(node.text, 8000); text(node.data, 16000);
    const initial = this.document.initial;
    for (const key of [node.bind, node.visibleKey]) {
      if (key !== undefined && (!uiIdentifier(key) || !Object.keys(initial).includes(key))) { fail(node.id + ': unknown state binding'); }
    }
    if (node.visibleKey !== undefined && typeof node.visibleValue !== typeof initial[node.visibleKey]) { fail(node.id + ': invalid visibility comparison'); }
    if (node.visibleKey === undefined && node.visibleValue !== undefined) { fail(node.id + ': missing visibility key'); }
    if (node.action !== undefined && (!uiIdentifier(node.action) || (!INPUTS.includes(node.kind) && node.kind !== 'button'))) { fail(node.id + ': invalid action'); }
    if (node.kind === 'button') { text(node.text, 200, true); if (!node.action) { fail(node.id + ': button needs action'); } }
    if (INPUTS.includes(node.kind) || node.kind === 'progress') {
      if (!node.bind) { fail(node.id + ': missing binding'); }
      const type = ['number', 'slider', 'progress'].includes(node.kind) ? 'number' : node.kind === 'toggle' ? 'boolean' : 'string';
      if (typeof initial[node.bind as string] !== type) { fail(node.id + ': incorrect binding type'); }
      text(node.text, 200, true);
    }
    if (node.kind === 'select' && (!Array.isArray(node.options) || node.options.length < 2 || node.options.length > 30 || node.options.some((option) => typeof option !== 'string' || option.length > 120) || new Set(node.options).size !== node.options.length)) { fail(node.id + ': invalid options'); }
    for (const value of [node.min, node.max, node.step]) {
      if (value !== undefined && (typeof value !== 'number' || !Number.isFinite(value))) { fail(node.id + ': invalid numeric range'); }
    }
    if ((node.min !== undefined && node.max !== undefined && node.min >= node.max) || (node.step !== undefined && node.step <= 0)) { fail(node.id + ': invalid range'); }
    if (['slider', 'progress'].includes(node.kind) && (node.min === undefined || node.max === undefined)) { fail(node.id + ': missing range'); }
    if (node.kind === 'image') {
      text(node.text, 500, true); text(node.source, 2000, true);
      if (!/^https:\/\/[^\s]+$/.test(node.source as string)) { fail(node.id + ': images require HTTPS'); }
    } else if (node.source !== undefined) { fail(node.id + ': source only supported by images'); }
    if (['data', 'scene'].includes(node.kind) && !node.data && !node.bind) { fail(node.id + ': data needs JSON or string binding'); }
    if (['data', 'scene'].includes(node.kind) && node.bind && typeof initial[node.bind] !== 'string') { fail(node.id + ': data binding must be JSON text'); }
    uiText(node.text || '', initial);
    let parent = node.parent; let depth = 0;
    while (parent) {
      const ancestor = this.document.nodes.find((item) => item.id === parent);
      if (!ancestor || !CONTAINERS.includes(ancestor.kind) || parent === node.id || ++depth > 8) { fail(node.id + ': invalid parent or excessive nesting'); }
      parent = ancestor.parent;
    }
    const index = this.document.nodes.findIndex((item) => item.id === node.id);
    if (index >= 0) {
      const previous = this.document.nodes[index];
      if (previous.kind !== node.kind || previous.parent !== node.parent) { fail(node.id + ': update changed kind or parent'); }
      this.document.nodes[index] = node;
    } else {
      if (this.document.nodes.length >= 128) { fail('more than 128 nodes'); }
      this.document.nodes.push(node);
    }
  }
  private action(action: UiAction): void {
    fields(action, ['id', 'kind', 'code', 'prompt', 'values']);
    if (!uiIdentifier(action.id) || !['compute', 'set', 'reset', 'submit'].includes(action.kind) || this.document.actions.length >= 32 || this.document.actions.some((item) => item.id === action.id)) { fail('invalid or duplicate action'); }
    if (action.kind === 'compute') { text(action.code, 16000, true); } else if (action.code !== undefined) { fail('code only allowed for compute'); }
    if (action.kind === 'submit') { text(action.prompt, 2000, true); } else if (action.prompt !== undefined) { fail('prompt only allowed for submit'); }
    if (action.kind === 'set') {
      validateUiValues(action.values as UiValues);
      for (const key of Object.keys(action.values as UiValues)) { if (typeof (action.values as UiValues)[key] !== typeof this.document.initial[key]) { fail('set changed state schema'); } }
    } else if (action.values !== undefined) { fail('values only allowed for set'); }
    this.document.actions.push(action);
  }
}
// Other code fences are never interpreted as UI, including examples nested in longer fences.
export function uiParts(content: string, streaming: boolean): UiPart[] {
  const parts: UiPart[] = []; let plain = ''; let body = ''; let inUi = false; let otherFence = ''; let fenceLength = 0; let ordinal = 0;
  const lines = content.split('\n');
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]; const newline = index < lines.length - 1 ? '\n' : ''; const complete = !!newline || !streaming;
    if (inUi) {
      if (!complete && /^`{1,3}\s*$/.test(line)) { continue; }
      if (complete && /^```\s*$/.test(line)) { parts.push({ kind: 'ui', key: String(ordinal++), content: body, closed: true }); body = ''; inUi = false; }
      else { body += line + newline; }
      continue;
    }
    const fence = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (!otherFence && complete && line.trimEnd() === '```tinybot-ui') {
      if (plain) { parts.push({ kind: 'text', key: 'text-' + ordinal, content: plain, closed: true }); plain = ''; }
      inUi = true; continue;
    }
    if (fence && complete) {
      if (!otherFence) { otherFence = fence[1][0]; fenceLength = fence[1].length; }
      else if (fence[1][0] === otherFence && fence[1].length >= fenceLength && !fence[2].trim()) { otherFence = ''; }
    }
    if (!complete && !otherFence && '```tinybot-ui'.startsWith(line) && line.startsWith('```')) { continue; }
    plain += line + newline;
  }
  if (inUi) { parts.push({ kind: 'ui', key: String(ordinal), content: body, closed: false }); }
  if (plain) { parts.push({ kind: 'text', key: 'text-' + ordinal, content: plain, closed: true }); }
  return parts;
}
export function parseUiSurface(content: string, key: string): UiDocument {
  const part = uiParts(content, false).find((item) => item.kind === 'ui' && item.key === key);
  if (!part || !part.closed) { return fail('surface is missing or not closed'); }
  return new UiCompiler().update(part.content, true);
}

export function validateUiAnswer(content: string): void {
  const surfaces = uiParts(content, false).filter((part) => part.kind === 'ui');
  if (surfaces.length > 8) { fail('more than 8 surfaces in one response'); }
  for (const part of surfaces) {
    if (!part.closed) { fail('missing closing UI fence'); }
    new UiCompiler().update(part.content, true);
  }
}
