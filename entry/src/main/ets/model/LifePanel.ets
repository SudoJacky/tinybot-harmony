// v1 keeps native cards; v2 uses the same sandboxed Web UI renderer as previews.
import { WebUiSpec, parseWebUi } from './WebUi';
import { PanelSchema, PanelInput, PanelInputs, PanelCheck, validatePanelSchema, checkPanelValue, resolvePanelInputs, validatePanelChecks } from './PanelContract';
import { MiniAppSnapshot } from './MiniApp';
import { PanelSource, validatePanelSource } from './PanelSource';
import { jsonPointer, pointerParts } from './PanelTransform';
export { PanelSource } from './PanelSource';
export interface PanelBinding { path?: string; value?: Object | null; }
interface PanelDataRoot { data: Object; state: Record<string, boolean>; }
export interface PanelNode {
  id: string; kind: string; parent?: string; text?: PanelBinding; value?: PanelBinding;
  max?: PanelBinding; items?: PanelBinding; tone?: string; suffix?: string; decimals?: number;
  private?: boolean; limit?: number; action?: string;
}
export interface PanelSpec {
  version: number; title: string; size: string; nodes: PanelNode[]; data: Object;
  source?: PanelSource; refreshMinutes?: number; view?: WebUiSpec;
  dataSchema?: PanelSchema; inputs?: Record<string, PanelInput>; checks?: PanelCheck[];
}
export interface PanelRecord {
  version: number; id: string; definition: PanelSpec; configRevision: number;
  sourcePath: string; sourceThreadId: string; data: Object; user: Record<string, boolean>;
  createdAt: number; updatedAt: number; refreshedAt: number; attemptedAt: number;
  error: string; archived: boolean;
  layout?: PanelLayout;
  paused?: boolean; runs?: PanelRun[]; viewState?: MiniAppSnapshot; inputs?: PanelInputs; runtimeError?: string; publicationKey?: string;
}
export interface PanelLayout { size: string; }
export interface PanelRun { id: string; startedAt: number; finishedAt: number; status: string; error: string; trigger?: string; failure?: PanelFailureInfo; }
export interface PanelFailureInfo { stage: string; code: string; message: string; tool?: string; nativeCode?: number; }
export interface PanelEntry { workspaceId: string; panel: PanelRecord; }
export function validatePanelViewState(snapshot: MiniAppSnapshot): void {
  if (!snapshot || typeof snapshot.revision !== 'string' || !snapshot.revision || snapshot.value === undefined ||
    snapshot.value !== null && typeof snapshot.value !== 'object' || JSON.stringify(snapshot).length > 256 * 1024) {
    throw new Error('Card state must be a JSON object or null, up to 256 KiB, with a revision');
  }
}
export interface PanelListQuery { workspaceId?: string; archived?: boolean; limit?: number; cursor?: string; }
export interface PanelSummary {
  workspaceId: string; panelId: string; title: string; size: string; sourceType: string; sourceWorkspaceId?: string;
  archived: boolean; paused: boolean; updatedAt: number; refreshedAt: number; taskStatus: string; error: string;
}
export interface PanelListPage { items: PanelSummary[]; nextCursor?: string; }
export interface PanelItem { id: string; label: string; value?: string; done?: boolean; }
export interface PanelCell { column: number; row: number; columns: number; rows: number; }
const KINDS: string[] = ['Row', 'Column', 'Text', 'Metric', 'Progress', 'ItemList', 'Checklist', 'Sparkline', 'ActionButton'];
const TONES: string[] = ['accent', 'neutral', 'positive', 'warning', 'negative'];
export function panelId(id: string): string {
  if (typeof id !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/.test(id)) { throw new Error('Invalid Life Panel ID'); }
  return id;
}
export function panelPath(id: string): string { return 'life-panels/' + panelId(id) + '/panel.json'; }
function object(value: Object | null | undefined): boolean { return !!value && typeof value === 'object' && !Array.isArray(value); }
function fields(value: Object, allowed: string[], label: string): void {
  if (!object(value) || Object.keys(value).some((key: string) => !allowed.includes(key))) { throw new Error('Invalid ' + label + ' fields'); }
}
export function panelPointer(root: Object, path: string): Object | null {
  return jsonPointer(root, path);
}
export function panelValue(binding: PanelBinding, data: Object, user: Record<string, boolean>): Object | null {
  const root: PanelDataRoot = { data: data, state: user };
  return binding.path !== undefined ? panelPointer(root, binding.path) : binding.value as Object | null;
}
function binding(value: PanelBinding | undefined, required: boolean): void {
  if (value === undefined && !required) { return; }
  if (!value) { throw new Error('Missing component binding'); }
  fields(value, ['path', 'value'], 'binding');
  if ((value.path === undefined) === (value.value === undefined)) { throw new Error('Binding requires exactly one of path or value'); }
  if (value.path !== undefined) {
    if (typeof value.path !== 'string' || !/^\/data(\/|$)/.test(value.path)) { throw new Error('Bind to /data'); }
    pointerParts(value.path);
  }
}
export function panelText(value: Object | null): string {
  if (typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean') { throw new Error('Expected text or a scalar value'); }
  return String(value);
}
export function panelNumber(value: Object | null): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) { throw new Error('Expected a finite numeric value'); }
  return value;
}
export function panelItems(value: Object | null): PanelItem[] {
  if (!Array.isArray(value) || value.length > 100) { throw new Error('Expected up to 100 list items'); }
  const ids: Set<string> = new Set<string>();
  for (const item of value as PanelItem[]) {
    if (!object(item) || typeof item.id !== 'string' || !item.id || typeof item.label !== 'string' ||
      (item.value !== undefined && typeof item.value !== 'string') || (item.done !== undefined && typeof item.done !== 'boolean') || ids.has(item.id)) {
      throw new Error('List items require unique id, label and optional string value / boolean done');
    }
    ids.add(item.id);
  }
  return value as PanelItem[];
}
export function panelPoints(value: Object | null): number[] {
  if (!Array.isArray(value) || value.length < 2 || value.length > 120) { throw new Error('Sparkline requires 2–120 numbers'); }
  return (value as Object[]).map((item: Object) => panelNumber(item));
}
export function validatePanelData(spec: PanelSpec, data: Object, user: Record<string, boolean>): void {
  if (data === null || typeof data !== 'object') { throw new Error('Panel data must be an object or array'); }
  if (JSON.stringify(data).length > 256 * 1024) { throw new Error('Panel data exceeds 256 KiB'); }
  if (spec.dataSchema) { checkPanelValue(spec.dataSchema, data); }
  for (const node of spec.nodes) {
    if (node.text) { panelText(panelValue(node.text, data, user)); }
    if (node.kind === 'Metric') { panelNumber(panelValue(node.value!, data, user)); }
    if (node.kind === 'Progress') {
      const value = panelNumber(panelValue(node.value!, data, user)), max = panelNumber(panelValue(node.max!, data, user));
      if (max <= 0 || value < 0 || value > max) { throw new Error('Progress must be between zero and a positive maximum'); }
    }
    if (node.items) { panelItems(panelValue(node.items, data, user)); }
    if (node.kind === 'Sparkline') { panelPoints(panelValue(node.value!, data, user)); }
  }
}
export function parsePanelSpec(content: string): PanelSpec {
  if (content.length > 384 * 1024) { throw new Error('Life Panel definition exceeds 384 KiB'); }
  const spec = JSON.parse(content) as PanelSpec;
  fields(spec, ['version', 'title', 'size', 'nodes', 'data', 'source', 'refreshMinutes', 'view', 'dataSchema', 'inputs', 'checks'], 'Life Panel');
  if (![1, 2].includes(spec.version) || typeof spec.title !== 'string' || !spec.title.trim() || spec.title.length > 80 ||
    !['S', 'M', 'L'].includes(spec.size) || !Array.isArray(spec.nodes) || spec.nodes.length > 32) { throw new Error('Invalid Life Panel version, title, size or nodes'); }
  if (spec.version === 1 && (!spec.nodes.length || spec.view !== undefined) || spec.version === 2 && (!spec.view || spec.nodes.length)) {
    throw new Error('Use v1 with native nodes, or v2 with view and empty nodes');
  }
  if (spec.view) { parseWebUi(JSON.stringify(spec.view)); }
  if (spec.dataSchema) { validatePanelSchema(spec.dataSchema); }
  if (spec.inputs) { resolvePanelInputs(spec.inputs); }
  if (spec.checks) { validatePanelChecks(spec.checks); }
  if (spec.source) { validatePanelSource(spec.source);
    if (spec.source.type === 'provider-balance') {
      const input = spec.inputs?.['providerId'];
      if (!input || input.type !== 'string' || !spec.source.providerIds!.includes(input.default as string) ||
        !input.options?.length || input.options.some((id) => typeof id !== 'string' || !spec.source!.providerIds!.includes(id as string))) {
        throw new Error('Provider balance requires a providerId string input with default/options from source.providerIds');
      }
    }
    for (const name of Object.values(spec.source.query || {})) { if (!spec.inputs?.[name]) { throw new Error('Query refers to undeclared input: ' + name); } }
  }
  if (spec.refreshMinutes !== undefined && (!Number.isInteger(spec.refreshMinutes) || spec.refreshMinutes < 1 || spec.refreshMinutes > 1440 || !spec.source)) { throw new Error('Automatic refresh requires a source and an interval of 1–1440 minutes'); }
  const parents: Map<string, PanelNode> = new Map<string, PanelNode>();
  for (const node of spec.nodes) {
    fields(node, ['id', 'kind', 'parent', 'text', 'value', 'max', 'items', 'tone', 'suffix', 'decimals', 'private', 'limit', 'action'], 'component');
    panelId(node.id);
    if (!KINDS.includes(node.kind) || parents.has(node.id) || (node.tone !== undefined && !TONES.includes(node.tone))) { throw new Error('Invalid component kind, ID or tone'); }
    if ((node.value !== undefined && !['Metric', 'Progress', 'Sparkline'].includes(node.kind)) ||
      (node.max !== undefined && node.kind !== 'Progress') || (node.items !== undefined && !['ItemList', 'Checklist'].includes(node.kind)) ||
      (node.text !== undefined && ['Row', 'Column'].includes(node.kind)) ||
      ((node.decimals !== undefined || node.suffix !== undefined) && node.kind !== 'Metric') ||
      (node.limit !== undefined && !['ItemList', 'Checklist'].includes(node.kind))) { throw new Error('Parameter is not supported by ' + node.kind); }
    if (node.parent !== undefined) {
      let parent = parents.get(node.parent), depth = 0;
      if (!parent || !['Row', 'Column'].includes(parent.kind)) { throw new Error('Declare Row/Column parents before their children'); }
      while (parent) { depth++; parent = parent.parent ? parents.get(parent.parent) : undefined; }
      if (depth > 4) { throw new Error('Component nesting exceeds four levels'); }
    }
    if (node.decimals !== undefined && (!Number.isInteger(node.decimals) || node.decimals < 0 || node.decimals > 4)) { throw new Error('decimals must be 0–4'); }
    if (node.suffix !== undefined && (typeof node.suffix !== 'string' || node.suffix.length > 12)) { throw new Error('suffix must be up to 12 characters'); }
    if (node.private !== undefined && (typeof node.private !== 'boolean' || node.kind !== 'Metric')) { throw new Error('private is a Metric parameter'); }
    if (node.limit !== undefined && (!Number.isInteger(node.limit) || node.limit < 1 || node.limit > 20)) { throw new Error('limit must be 1–20'); }
    if (node.action !== undefined && (node.action !== 'refresh' || node.kind !== 'ActionButton')) { throw new Error('Only ActionButton refresh is supported'); }
    if (node.kind === 'ActionButton' && (node.action !== 'refresh' || !spec.source)) { throw new Error('Refresh buttons require a refreshable source'); }
    binding(node.text, ['Text', 'ActionButton'].includes(node.kind));
    binding(node.value, ['Metric', 'Progress', 'Sparkline'].includes(node.kind));
    binding(node.max, node.kind === 'Progress'); binding(node.items, ['ItemList', 'Checklist'].includes(node.kind));
    parents.set(node.id, node);
  }
  validatePanelData(spec, spec.data, {});
  return spec;
}
export function parsePanelRecord(content: string, id: string): PanelRecord {
  const record = JSON.parse(content) as PanelRecord;
  if (!object(record) || record.version !== 1 || record.id !== panelId(id) || !Number.isSafeInteger(record.configRevision) || record.configRevision < 1 ||
    typeof record.archived !== 'boolean' || typeof record.error !== 'string' || typeof record.sourcePath !== 'string' || typeof record.sourceThreadId !== 'string' ||
    !object(record.user) || Object.keys(record.user).some((key: string) => typeof record.user[key] !== 'boolean') ||
    [record.createdAt, record.updatedAt, record.refreshedAt, record.attemptedAt].some((value: number) => !Number.isFinite(value) || value < 0)) { throw new Error('Invalid Life Panel record'); }
  parsePanelSpec(JSON.stringify(record.definition)); validatePanelData(record.definition, record.data, record.user);
  if (record.layout !== undefined && (!object(record.layout) || !['S', 'M', 'L'].includes(record.layout.size) ||
    Object.keys(record.layout).some((key: string) => key !== 'size'))) { throw new Error('Invalid card layout'); }
  if (record.inputs !== undefined) { resolvePanelInputs(record.definition.inputs, record.inputs); }
  if (record.runtimeError !== undefined && (typeof record.runtimeError !== 'string' || record.runtimeError.length > 4000)) { throw new Error('Invalid card runtime error'); }
  if (record.publicationKey !== undefined && typeof record.publicationKey !== 'string') { throw new Error('Invalid publication key'); }
  if (record.viewState !== undefined) { validatePanelViewState(record.viewState); }
  if ((record.paused !== undefined && typeof record.paused !== 'boolean') || (record.runs !== undefined && (!Array.isArray(record.runs) || record.runs.length > 10 ||
    record.runs.some((run: PanelRun) => !run || typeof run.id !== 'string' || !Number.isFinite(run.startedAt) || !Number.isFinite(run.finishedAt) ||
      !['running', 'complete', 'failed', 'cancelled', 'interrupted'].includes(run.status) || typeof run.error !== 'string')))) { throw new Error('Invalid panel task history'); }
  for (const run of record.runs || []) {
    if (run.trigger !== undefined && !['manual', 'automatic'].includes(run.trigger)) { throw new Error('Invalid panel run trigger'); }
    if (run.failure && (!object(run.failure) || !['tool', 'runtime', 'model', 'output', 'acquisition', 'validation'].includes(run.failure.stage) ||
      typeof run.failure.code !== 'string' || !/^[A-Z_]{1,64}$/.test(run.failure.code) || typeof run.failure.message !== 'string' || run.failure.message.length > 1000 ||
      run.failure.nativeCode !== undefined && (typeof run.failure.nativeCode !== 'number' || !Number.isFinite(run.failure.nativeCode)) ||
      run.failure.tool !== undefined && (typeof run.failure.tool !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(run.failure.tool)))) { throw new Error('Invalid panel failure evidence'); }
  }
  return record;
}
export function panelDue(record: PanelRecord, now: number): boolean {
  return !record.archived && !record.paused && !!record.definition.source && !!record.definition.refreshMinutes &&
    now >= Math.max(record.refreshedAt, record.attemptedAt) + record.definition.refreshMinutes! * 60000;
}
// First-fit placement preserves S=1x1, M=2x1, L=2x2 without holes caused by row height.
export function panelCells(sizes: string[], columns: number): PanelCell[] {
  const occupied: Set<number> = new Set<number>(), result: PanelCell[] = [];
  for (const size of sizes) {
    const width = size === 'S' ? 1 : Math.min(2, columns), height = size === 'L' ? 2 : 1;
    let offset = 0;
    while (true) {
      const column = offset % columns, row = Math.floor(offset / columns);
      let fits = column + width <= columns;
      for (let y = 0; y < height; y++) { for (let x = 0; x < width; x++) { if (occupied.has((row + y) * columns + column + x)) { fits = false; } } }
      if (fits) {
        result.push({ column: column, row: row, columns: width, rows: height });
        for (let y = 0; y < height; y++) { for (let x = 0; x < width; x++) { occupied.add((row + y) * columns + column + x); } }
        break;
      }
      offset++;
    }
  }
  return result;
}
