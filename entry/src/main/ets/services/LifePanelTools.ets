import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { LifePanels } from './LifePanels';
import { LIFE_PANEL_CATALOG, panelId, parsePanelSpec, PanelListQuery } from '../model/LifePanel';
import { WorkspaceFiles } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';
import { Cancellation } from './Cancellation';
import { LifeBoards } from './LifeBoards';
import { BoardItem } from '../model/LifeBoard';
interface PublishPanelArguments { path?: string; panelId?: string; workspaceId?: string; boardId?: string; boardWorkspaceId?: string; action?: string; title?: string; description?: string; items?: BoardItem[]; section?: string; }
export class LifePanelTools implements AgentTools {
  private panels: LifePanels;
  private workspaceId: string;
  private threadId: string;
  private files: WorkspaceFiles;
  private boards?: LifeBoards;
  constructor(panels: LifePanels, workspaceId: string, threadId: string, files: WorkspaceFiles, boards?: LifeBoards) {
    this.panels = panels; this.workspaceId = workspaceId; this.threadId = threadId; this.files = files;
    this.boards = boards;
  }
  definitions(): ToolDefinition[] {
    return [
      { type: 'function', function: { name: 'get_life_panel_catalog', description: 'Read the Life Panel v1 native component protocol, bindings, API/mail/Agent sources, sizes and examples before authoring a persistent dashboard card.', parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } },
      { type: 'function', function: { name: 'list_life_panels', description: 'Page through compact card summaries across the app, without data snapshots, definitions, scripts or history. Optional workspace/archived filters. Follow nextCursor even for an empty page. Reuse workspaceId/panelId with get_life_panel for selected details.', parameters: { type: 'object', properties: {
        'workspaceId': { type: 'string', description: 'Optional owner workspace filter' }, 'archived': { type: 'boolean', description: 'False by default; true lists archived cards' },
        'limit': { type: 'integer', description: '1–20 summaries, default 10; at most 50 manifests are read per page' }, 'cursor': { type: 'string', description: 'nextCursor from the same filters' }
      }, required: [], additionalProperties: false } } },
      { type: 'function', function: { name: 'get_life_panel', description: 'Read one selected card by owner workspaceId and panelId. section defaults to all; choose definition, data or task to avoid unrelated large snapshots. Contains full detail only when explicitly requested.', parameters: { type: 'object', properties: {
        'workspaceId': { type: 'string', description: 'Owner workspace ID' }, 'panelId': { type: 'string', description: 'Card ID' },
        'section': { type: 'string', enum: ['all', 'definition', 'data', 'task'], description: 'Requested detail section' }
      }, required: ['workspaceId', 'panelId'], additionalProperties: false } } },
      { type: 'function', executionMode: 'sequential', function: { name: 'publish_life_panel', description: 'Publish a native card from a .panel.json file in this chat workspace. Existing panelId + workspaceId update the SAME shared card across all boards, preserving checklist edits. Optional boardId/boardWorkspaceId pins the card by reference. Reads the component catalog first. source supports API, workspace-json or agent:{prompt}; refreshMinutes schedules foreground updates. Scripts only run as sandboxed data transforms. Users manage credentials in card API connection. Successful receipts display a live card in chat.', parameters: { type: 'object', properties: { 'path': { type: 'string', description: 'Workspace .panel.json definition path' }, 'panelId': { type: 'string', description: 'Existing ID when updating; omit to create' }, 'workspaceId': { type: 'string', description: 'Owner workspace for an existing card; defaults to current' }, 'boardId': { type: 'string', description: 'Optional board to pin into' }, 'boardWorkspaceId': { type: 'string', description: 'Board owner workspace' } }, required: ['path'], additionalProperties: false } } },
      { type: 'function', function: { name: 'list_life_boards', description: 'List all persistent Life Panel boards and card references. Same card ID can occur in multiple boards, sharing data and user state.', parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } },
      { type: 'function', executionMode: 'sequential', function: { name: 'manage_life_board', description: 'Create or update a named board. action: save, archive or restore. Omit boardId to create. items optionally replaces layout/order using existing {workspaceId,panelId,size:S/M/L} card references. Omitting items preserves layout. Removing a reference does not delete the card. Returns a clickable board receipt in chat.', parameters: { type: 'object', properties: {
        'action': { type: 'string', enum: ['save', 'archive', 'restore'], description: 'Board operation' }, 'boardId': { type: 'string', description: 'Existing board ID' }, 'workspaceId': { type: 'string', description: 'Board owner; defaults to current' }, 'title': { type: 'string', description: 'Required name for a new board' }, 'description': { type: 'string', description: 'Optional description' }, 'items': { type: 'array', description: 'Optional complete ordered layout', items: { type: 'object', description: 'Card reference', properties: { 'workspaceId': { type: 'string', description: 'Card owner' }, 'panelId': { type: 'string', description: 'Shared card ID' }, 'size': { type: 'string', enum: ['S', 'M', 'L'], description: 'Size on this board' } }, required: ['workspaceId', 'panelId', 'size'], additionalProperties: false } }
      }, required: ['action'], additionalProperties: false } } },
      { type: 'function', executionMode: 'sequential', function: { name: 'manage_life_panel_task', description: 'Pause/resume automatic updates or manually refresh one existing card. Includes API data refresh and bounded read-only Agent content updates. Inspect list_life_panels for recent runs/errors. Does not require the source chat.', parameters: { type: 'object', properties: { 'panelId': { type: 'string', description: 'Card ID' }, 'workspaceId': { type: 'string', description: 'Card owner' }, 'action': { type: 'string', enum: ['pause', 'resume', 'refresh'], description: 'Task operation' } }, required: ['panelId', 'workspaceId', 'action'], additionalProperties: false } } }
    ];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    const args = parseToolArguments(call.function.arguments) as PublishPanelArguments;
    if (!args || typeof args !== 'object' || Array.isArray(args)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Expected an object', 'fix_arguments'); }
    cancellation.check();
    if (call.function.name === 'list_life_panels') { return JSON.stringify(await this.panels.page(args as PanelListQuery)); }
    if (call.function.name === 'get_life_panel') {
      if (Object.keys(args).some((key: string) => !['workspaceId', 'panelId', 'section'].includes(key)) || typeof args.workspaceId !== 'string' || typeof args.panelId !== 'string' || !['all', 'definition', 'data', 'task'].includes(args.section || 'all')) { throw new Error('Invalid card detail request'); }
      const panel = await this.panels.repository(args.workspaceId).get(args.panelId);
      if (!args.section || args.section === 'all') { return JSON.stringify({ workspaceId: args.workspaceId, panel: panel }); }
      if (args.section === 'definition') { return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, definition: panel.definition, configRevision: panel.configRevision }); }
      if (args.section === 'data') { return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, data: panel.data, user: panel.user, refreshedAt: panel.refreshedAt }); }
      return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, paused: panel.paused, runs: panel.runs || [], error: panel.error, running: this.panels.repository(args.workspaceId).isRefreshing(panel.id) });
    }
    if (['get_life_panel_catalog', 'list_life_boards'].includes(call.function.name)) {
      if (Object.keys(args).length) { throw new ToolFailure('INVALID_ARGUMENTS', 'No arguments expected', 'fix_arguments'); }
      if (call.function.name === 'get_life_panel_catalog') { return LIFE_PANEL_CATALOG; }
      if (call.function.name === 'list_life_boards') { if (!this.boards) { throw new Error('Board store is unavailable'); } return JSON.stringify(await this.boards.list()); }
    }
    if (call.function.name === 'manage_life_panel_task') {
      if (Object.keys(args).some((key) => !['panelId', 'workspaceId', 'action'].includes(key)) || typeof args.panelId !== 'string' || typeof args.workspaceId !== 'string' || !['pause', 'resume', 'refresh'].includes(args.action || '')) { throw new Error('Invalid card task operation'); }
      const repository = this.panels.repository(args.workspaceId);
      return JSON.stringify(args.action === 'refresh' ? await repository.refresh(args.panelId, cancellation) : await repository.pause(args.panelId, args.action === 'pause'));
    }
    if (call.function.name === 'manage_life_board') {
      if (!this.boards) { throw new Error('Board store is unavailable'); }
      if (Object.keys(args).some((key) => !['action', 'boardId', 'workspaceId', 'title', 'description', 'items'].includes(key)) || !['save', 'archive', 'restore'].includes(args.action || '') ||
        (args.workspaceId !== undefined && typeof args.workspaceId !== 'string') || (args.boardId !== undefined && typeof args.boardId !== 'string') || (args.title !== undefined && typeof args.title !== 'string') || (args.description !== undefined && typeof args.description !== 'string')) { throw new Error('Invalid board operation'); }
      const owner = args.workspaceId || this.workspaceId;
      if (!args.boardId && owner !== this.workspaceId) { throw new Error('Create boards in the current workspace'); }
      const before = args.boardId ? await this.boards.get(owner, args.boardId) : undefined;
      if (args.action !== 'save' && !before) { throw new Error('Select an existing board'); }
      const board = await this.boards.save(owner, args.boardId || '', args.title === undefined ? before?.title || '' : args.title,
        args.description === undefined ? before?.description || '' : args.description, args.items, args.action === 'save' ? undefined : args.action === 'archive');
      return JSON.stringify({ boardId: board.id, workspaceId: owner, title: board.title, openFrom: 'Life Panel' });
    }
    if (call.function.name !== 'publish_life_panel') { throw new ToolFailure('TOOL_UNAVAILABLE', 'Unknown Life Panel tool', 'check_available_tools'); }
    if (Object.keys(args).some((key: string) => !['path', 'panelId', 'workspaceId', 'boardId', 'boardWorkspaceId'].includes(key)) || typeof args.path !== 'string' || !args.path.endsWith('.panel.json') ||
      [args.panelId, args.workspaceId, args.boardId, args.boardWorkspaceId].some((value: string | undefined) => value !== undefined && typeof value !== 'string')) { throw new ToolFailure('INVALID_ARGUMENTS', 'Expected .panel.json path and optional card/board IDs', 'fix_arguments'); }
    const path = workspaceRelativePath(args.path, false), id = args.panelId === undefined ? this.panels.createId() : panelId(args.panelId);
    const spec = parsePanelSpec((await this.files.read(path, cancellation)).content);
    const owner = args.workspaceId || this.workspaceId;
    if (!args.panelId && owner !== this.workspaceId) { throw new Error('Create cards in the current workspace'); }
    if (spec.source?.type === 'workspace-json') {
      if (owner !== this.workspaceId && spec.source.workspaceId === undefined) {
        throw new Error('Cross-chat workspace-json updates require explicit source.workspaceId; choose the original owner or the current workspace before publishing');
      }
      if (spec.source.workspaceId === undefined) { spec.source.workspaceId = this.workspaceId; }
    }
    if (args.boardId) {
      if (!this.boards) { throw new Error('Board store is unavailable'); }
      if ((await this.boards.get(args.boardWorkspaceId || this.workspaceId, args.boardId)).archived) { throw new Error('Restore the board before publishing into it'); }
    }
    const record = await this.panels.repository(owner).publish(id, spec, path, this.threadId, args.panelId !== undefined, cancellation);
    if (args.boardId) {
      try { await this.boards!.pin(args.boardWorkspaceId || this.workspaceId, args.boardId, { workspaceId: owner, panelId: id }, true); }
      catch (error) { throw new Error('Card ' + owner + '/' + id + ' was published, but board pinning failed: ' + (error as Error).message); }
    }
    return JSON.stringify({ panelId: id, workspaceId: owner, title: record.definition.title, size: record.definition.size, published: true, openFrom: 'Life Panel', sourceStatus: 'not_checked' });
  }
}
