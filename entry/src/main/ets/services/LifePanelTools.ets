import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { ToolFailure, ToolFailureDetails, parseToolArguments } from '../model/ToolFailure';
import { LifePanels } from './LifePanels';
import { providerBalanceCatalog } from './ProviderBalanceCatalog';
import { LIFE_PANEL_CATALOG, lifePanelCatalog, panelId, parsePanelSpec, PanelListQuery, PanelSpec } from '../model/LifePanel';
import { miniAppPage } from '../model/MiniApp';
import { MiniAppStorage, MiniAppSnapshot } from '../model/MiniApp';
import { PanelValidationStorage } from './PanelValidationStorage';
import { PanelProbeOptions, PanelInputs, reconcilePanelInputs } from '../model/PanelContract';
import { PanelTaskFailure } from './PanelTaskFailure';
import { WebUiPanelContext } from '../model/WebUi';
import { getLocale } from '../model/I18n';
import { WorkspaceFiles } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';
import { Cancellation } from './Cancellation';
import { LifeBoards } from './LifeBoards';
import { BoardItem } from '../model/LifeBoard';
interface PanelRevisionResult { configRevision: number; }
interface PanelPinResult { panelId: string; workspaceId: string; published: boolean; pinned: boolean; boardId?: string; }
interface PublishPanelArguments { path?: string; htmlPath?: string; panelId?: string; workspaceId?: string; boardId?: string; boardWorkspaceId?: string; action?: string; title?: string; description?: string; items?: BoardItem[]; section?: string; requestId?: string; expectedRevision?: number; replaceData?: boolean; checkSource?: boolean; viewportWidth?: number; inputs?: PanelInputs; }
export class LifePanelTools implements AgentTools {
  private panels: LifePanels;
  private workspaceId: string;
  private threadId: string;
  private files: WorkspaceFiles;
  private boards?: LifeBoards;
  private validate?: (page: string, storage: MiniAppStorage, context: WebUiPanelContext, cancellation: Cancellation, options?: PanelProbeOptions) => Promise<void>;
  constructor(panels: LifePanels, workspaceId: string, threadId: string, files: WorkspaceFiles, boards?: LifeBoards,
    validate?: (page: string, storage: MiniAppStorage, context: WebUiPanelContext, cancellation: Cancellation, options?: PanelProbeOptions) => Promise<void>) {
    this.panels = panels; this.workspaceId = workspaceId; this.threadId = threadId; this.files = files;
    this.boards = boards;
    this.validate = validate;
  }
  definitions(): ToolDefinition[] {
    return [
      { type: 'function', function: { name: 'get_life_panel_catalog', description: 'Read Life Panel authoring guidance. Use section:html for the interactive starter and validation contract, native for native components, sources for acquisition options, balance for configured provider accounts and a wallet-style HTML reference, all for complete reference.', parameters: { type: 'object', properties: { 'section': { type: 'string', enum: ['all', 'html', 'native', 'sources', 'balance'], description: 'Requested protocol section' } }, required: [], additionalProperties: false } } },
      { type: 'function', function: { name: 'list_life_panels', description: 'Page through compact card summaries across the app, without data snapshots, definitions, scripts or history. Optional workspace/archived filters. Follow nextCursor even for an empty page. Reuse workspaceId/panelId with get_life_panel for selected details.', parameters: { type: 'object', properties: {
        'workspaceId': { type: 'string', description: 'Optional owner workspace filter' }, 'archived': { type: 'boolean', description: 'False by default; true lists archived cards' },
        'limit': { type: 'integer', description: '1–20 summaries, default 10; at most 50 manifests are read per page' }, 'cursor': { type: 'string', description: 'nextCursor from the same filters' }
      }, required: [], additionalProperties: false } } },
      { type: 'function', function: { name: 'get_life_panel', description: 'Read one selected card by owner workspaceId and panelId. section defaults to all; choose definition, data or task to avoid unrelated large snapshots. Contains full detail only when explicitly requested.', parameters: { type: 'object', properties: {
        'workspaceId': { type: 'string', description: 'Owner workspace ID' }, 'panelId': { type: 'string', description: 'Card ID' },
        'section': { type: 'string', enum: ['all', 'definition', 'data', 'task'], description: 'Requested detail section' }
      }, required: ['workspaceId', 'panelId'], additionalProperties: false } } },
      this.publicationTool(false), this.publicationTool(true),
      { type: 'function', function: { name: 'list_life_boards', description: 'List all persistent Life Panel boards and card references. Same card ID can occur in multiple boards, sharing data and user state.', parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } },
      { type: 'function', executionMode: 'sequential', function: { name: 'manage_life_board', description: 'Create or update a named board. action: save, archive or restore. Omit boardId to create. items optionally replaces layout using existing {workspaceId,panelId,x,y,w,h} card references on a 12-column grid; integer x/y >=0, w/h 2..12, x+w<=12, no overlaps; y may extend below the viewport. Omitting items preserves layout. Removing a reference does not delete the card. Returns a clickable board receipt in chat.', parameters: { type: 'object', properties: {
        'action': { type: 'string', enum: ['save', 'archive', 'restore'], description: 'Board operation' }, 'boardId': { type: 'string', description: 'Existing board ID' }, 'workspaceId': { type: 'string', description: 'Board owner; defaults to current' }, 'title': { type: 'string', description: 'Required name for a new board' }, 'description': { type: 'string', description: 'Optional description' }, 'items': { type: 'array', description: 'Optional complete grid layout', items: { type: 'object', description: 'Card reference', properties: { 'workspaceId': { type: 'string', description: 'Card owner' }, 'panelId': { type: 'string', description: 'Shared card ID' }, 'x': { type: 'integer', minimum: 0, maximum: 10, description: 'Left column' }, 'y': { type: 'integer', minimum: 0, description: 'Top row' }, 'w': { type: 'integer', minimum: 2, maximum: 12, description: 'Width in cells' }, 'h': { type: 'integer', minimum: 2, maximum: 12, description: 'Height in cells' } }, required: ['workspaceId', 'panelId', 'x', 'y', 'w', 'h'], additionalProperties: false } }
      }, required: ['action'], additionalProperties: false } } },
      { type: 'function', executionMode: 'sequential', function: { name: 'manage_life_panel_task', description: 'Pause/resume automatic updates or manually refresh one existing card. Includes API data refresh and bounded read-only Agent content updates. Inspect list_life_panels for recent runs/errors. Does not require the source chat.', parameters: { type: 'object', properties: { 'panelId': { type: 'string', description: 'Card ID' }, 'workspaceId': { type: 'string', description: 'Card owner' }, 'action': { type: 'string', enum: ['pause', 'resume', 'refresh'], description: 'Task operation' }, 'inputs': { type: 'object', description: 'Optional declared input values for a manual refresh, merged with current inputs', additionalProperties: true } }, required: ['panelId', 'workspaceId', 'action'], additionalProperties: false } } }
    ];
  }
  private publicationTool(validateOnly: boolean): ToolDefinition {
    const properties: Record<string, ToolProperty> = {
      'path': { type: 'string', description: 'Current workspace .panel.json path. Read catalog for template and checks.' },
      'htmlPath': { type: 'string', description: 'Self-contained HTML; optional when view is embedded. Uses definition view height if supplied, otherwise 320.' },
      'panelId': { type: 'string', description: 'Existing card ID for update/validation against saved user state.' },
      'workspaceId': { type: 'string', description: 'Existing card owner, defaults to current workspace.' },
      'expectedRevision': { type: 'integer', description: 'Required for updates: configRevision from get_life_panel. Rejects stale edits.', minimum: 1 },
      'replaceData': { type: 'boolean', description: 'False by default: preserve current live data on updates. True explicitly replaces it with the tested source/initial snapshot.' },
      'checkSource': { type: 'boolean', description: 'Default true: run configured source without persisting. False explicitly defers connection/source setup and is reported as not_checked.' },
      'viewportWidth': { type: 'integer', description: 'Full-card width in vp from board context, 160–1200; checks run here and half width.', minimum: 160, maximum: 1200 }
    };
    if (!validateOnly) {
      properties['requestId'] = { type: 'string', description: 'Stable unique identifier (letters/digits/-/_, up to 64) for one new-card intent. Retrying reuses its card; to edit use panelId + expectedRevision.' };
      properties['boardId'] = { type: 'string', description: 'Board to pin into after publication' };
      properties['boardWorkspaceId'] = { type: 'string', description: 'Board owner workspace' };
    }
    return { type: 'function', executionMode: 'sequential',
      promptGuidelines: ['Create/edit loop: read catalog and current card, write candidate files with dataSchema and checks, call validate_life_panel, repair every returned diagnostic and repeat. Publish only after passing. If source requires credentials, explicitly defer its check and explain the pending connection. Never claim declared checks prove all possible interactions. Use the original ID and expectedRevision on updates.'],
      function: { name: validateOnly ? 'validate_life_panel' : 'publish_life_panel',
        description: validateOnly ? 'Test a candidate without changing the card: schema, source query, HTML startup at two widths, declared interaction/storage assertions, horizontal overflow and control labels. Returns structured stage/path/check diagnostics to repair and retry. State is detached; checks cannot execute live refresh tasks.' :
          'Validate then publish native/HTML card. size is a legacy definition field; board geometry uses x/y/w/h; updates preserve user layout, live data and user state by default; no version restore. requestId makes new-card retries idempotent. Structured pin failures retain published ID for recovery. Explicit source failures block publication; checkSource:false is reserved for pending connection/setup, never hides a tested failure.',
        parameters: { type: 'object', properties: properties, required: ['path'], additionalProperties: false } } };
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    try { return await this.executeChecked(call, cancellation); }
    catch (error) {
      cancellation.check();
      if (error instanceof ToolFailure) { throw error; }
      throw new ToolFailure('PANEL_OPERATION_FAILED', (error as Error).message, 'inspect_card_fix_and_validate_again');
    }
  }
  private async executeChecked(call: ToolCall, cancellation: Cancellation): Promise<string> {
    const args = parseToolArguments(call.function.arguments) as PublishPanelArguments;
    if (!args || typeof args !== 'object' || Array.isArray(args)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Expected an object', 'fix_arguments'); }
    cancellation.check();
    if (call.function.name === 'list_life_panels') { return JSON.stringify(await this.panels.page(args as PanelListQuery)); }
    if (call.function.name === 'get_life_panel') {
      if (Object.keys(args).some((key: string) => !['workspaceId', 'panelId', 'section'].includes(key)) || typeof args.workspaceId !== 'string' || typeof args.panelId !== 'string' || !['all', 'definition', 'data', 'task'].includes(args.section || 'all')) { throw new Error('Invalid card detail request'); }
      const panel = await this.panels.repository(args.workspaceId).get(args.panelId);
      if (!args.section || args.section === 'all') { return JSON.stringify({ workspaceId: args.workspaceId, panel: panel }); }
      if (args.section === 'definition') { return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, definition: panel.definition, layout: panel.layout, configRevision: panel.configRevision }); }
      if (args.section === 'data') { return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, data: panel.data, user: panel.user, viewState: panel.viewState, inputs: panel.inputs, refreshedAt: panel.refreshedAt }); }
      return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, paused: panel.paused, runs: panel.runs || [], error: panel.error, runtimeError: panel.runtimeError, running: this.panels.repository(args.workspaceId).isRefreshing(panel.id) });
    }
    if (['get_life_panel_catalog', 'list_life_boards'].includes(call.function.name)) {
      if (Object.keys(args).some((key: string) => call.function.name !== 'get_life_panel_catalog' || key !== 'section')) { throw new ToolFailure('INVALID_ARGUMENTS', 'Unexpected catalog/list arguments', 'fix_arguments'); }
      if (call.function.name === 'get_life_panel_catalog') { return args.section === 'balance' ? providerBalanceCatalog() : lifePanelCatalog(args.section); }
      if (call.function.name === 'list_life_boards') { if (!this.boards) { throw new Error('Board store is unavailable'); } return JSON.stringify(await this.boards.list()); }
    }
    if (call.function.name === 'manage_life_panel_task') {
      if (args.inputs !== undefined && args.action !== 'refresh') { throw new Error('inputs requires action refresh'); }
      if (Object.keys(args).some((key) => !['panelId', 'workspaceId', 'action', 'inputs'].includes(key)) || typeof args.panelId !== 'string' || typeof args.workspaceId !== 'string' || !['pause', 'resume', 'refresh'].includes(args.action || '')) { throw new Error('Invalid card task operation'); }
      const repository = this.panels.repository(args.workspaceId);
      return JSON.stringify(args.action === 'refresh' ? await repository.refresh(args.panelId, cancellation, 'manual', args.inputs) : await repository.pause(args.panelId, args.action === 'pause'));
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
    if (!['publish_life_panel', 'validate_life_panel'].includes(call.function.name)) { throw new ToolFailure('TOOL_UNAVAILABLE', 'Unknown Life Panel tool', 'check_available_tools'); }
    const validating = call.function.name === 'validate_life_panel';
    if (validating && [args.requestId, args.boardId, args.boardWorkspaceId].some((value: string | undefined) => value !== undefined)) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Validation does not accept publication or pinning arguments', 'remove_publication_arguments');
    }
    if (Object.keys(args).some((key: string) => !['path', 'htmlPath', 'panelId', 'workspaceId', 'boardId', 'boardWorkspaceId', 'requestId', 'expectedRevision', 'replaceData', 'checkSource', 'viewportWidth'].includes(key)) || typeof args.path !== 'string' || !args.path.endsWith('.panel.json') ||
      [args.panelId, args.workspaceId, args.boardId, args.boardWorkspaceId].some((value: string | undefined) => value !== undefined && typeof value !== 'string') ||
      [args.replaceData, args.checkSource].some((value: boolean | undefined) => value !== undefined && typeof value !== 'boolean') ||
      args.requestId !== undefined && (typeof args.requestId !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(args.requestId)) ||
      args.viewportWidth !== undefined && (!Number.isInteger(args.viewportWidth) || args.viewportWidth < 160 || args.viewportWidth > 1200)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Invalid card validation/publication arguments', 'fix_arguments'); }
    const path = workspaceRelativePath(args.path, false), owner = args.workspaceId || this.workspaceId;
    if (!args.panelId && owner !== this.workspaceId) { throw new Error('Create cards in the current workspace'); }
    const id = args.panelId ? panelId(args.panelId) : args.requestId ? 'panel-' + args.requestId : this.panels.createId();
    const repository = this.panels.repository(owner);
    const previous = args.panelId ? await repository.get(id) : args.requestId ? await repository.lookup(id) : undefined;
    if (!args.panelId && previous) {
      if (previous.publicationKey !== args.requestId) { throw new ToolFailure('PANEL_ID_CONFLICT', 'Identifier belongs to another card', 'choose_new_request_id'); }
      if (args.boardId) { await this.pinPublished(owner, id, args); }
      return JSON.stringify({ panelId: id, workspaceId: owner, title: previous.definition.title, published: true, reused: true, openFrom: 'Life Panel' });
    }
    if (previous && (!Number.isInteger(args.expectedRevision) || args.expectedRevision !== previous.configRevision)) { throw new ToolFailure('PANEL_REVISION_CONFLICT', 'Provide current configRevision as expectedRevision', 'get_life_panel', { result: { configRevision: previous.configRevision } as PanelRevisionResult } as ToolFailureDetails); }
    let stage = 'definition';
    try {
      const definition = JSON.parse((await this.files.read(path, cancellation)).content) as PanelSpec;
      if (args.htmlPath !== undefined) {
        if (typeof args.htmlPath !== 'string' || !args.htmlPath.endsWith('.html') || definition?.version !== 2) { throw new Error('htmlPath requires v2 and a workspace .html file'); }
        const height = definition.view?.height || 320;
        definition.view = miniAppPage(args.htmlPath, (await this.files.read(workspaceRelativePath(args.htmlPath, false), cancellation)).content); definition.view.height = height;
      }
      const spec = parsePanelSpec(JSON.stringify(definition));
      if (spec.view && (!spec.dataSchema || !spec.checks)) { throw new ToolFailure('PANEL_CONTRACT_REQUIRED', 'HTML authoring requires dataSchema and checks (use [] for display-only cards); read catalog section html', 'add_schema_and_interaction_checks', { path: path }); }
      if (spec.source?.type === 'workspace-json') {
        if (owner !== this.workspaceId && spec.source.workspaceId === undefined) { throw new Error('Cross-chat workspace-json updates require explicit source.workspaceId'); }
        if (spec.source.workspaceId === undefined) { spec.source.workspaceId = this.workspaceId; }
      }
      const inputs = reconcilePanelInputs(spec.inputs, previous?.inputs || {});
      const retained = previous && !args.replaceData ? previous.data : spec.data;
      // Validate retained data too: changing a view must not silently replace its live snapshot.
      const candidate = JSON.parse(JSON.stringify(spec)) as PanelSpec; candidate.data = retained;
      parsePanelSpec(JSON.stringify(candidate));
      stage = 'source';
      const testedData = args.checkSource === false ? retained : await repository.probe(spec, id, retained, inputs, cancellation);
      const widths: number[] = spec.view ? [Math.max(160, Math.round(((args.viewportWidth || 360) - 12) / 2)), args.viewportWidth || 360] : [];
      stage = 'render';
      if (spec.view) {
        if (!this.validate) { throw new Error('Interactive card validation is unavailable'); }
        const context: WebUiPanelContext = { data: testedData, inputs: inputs, title: spec.title, status: 'ready', canRefresh: !!spec.source, locale: getLocale() };
        for (const width of widths) {
          const storage = new PanelValidationStorage(previous?.viewState || { value: null, revision: 'initial' });
          try {
            await this.validate(JSON.stringify(spec.view), storage, context, cancellation, { width: width, checks: spec.checks || [] });
            // Reopen with the state produced by the interaction checks, without replaying them.
            if (spec.checks?.length) { await this.validate(JSON.stringify(spec.view), storage, context, cancellation, { width: width, checks: [] }); }
          } catch (error) { throw new Error('width=' + width + ': ' + (error as Error).message); }
        }
        if (previous && !args.replaceData && JSON.stringify(testedData) !== JSON.stringify(retained)) {
          await this.validate(JSON.stringify(spec.view), new PanelValidationStorage(previous.viewState || { value: null, revision: 'initial' }),
            { data: retained, inputs: inputs, title: spec.title, status: 'ready', canRefresh: !!spec.source, locale: getLocale() }, cancellation, { width: args.viewportWidth || 360, checks: [] });
        }
      }
      const warnings: string[] = [];
      if (spec.view && !spec.dataSchema) { warnings.push('No dataSchema: HTML task output shape is not enforced. Add an explicit schema.'); }
      if (spec.view && !spec.checks?.length) { warnings.push('No interaction checks declared: only startup/layout/labels checked.'); }
      if (args.checkSource === false && spec.source) { warnings.push('Source was explicitly not checked; connection/setup remains pending.'); }
      const sourceStatus = spec.source ? args.checkSource === false ? 'not_checked' : 'passed' : 'not_applicable';
      if (validating) { return JSON.stringify({ valid: true, widths: widths, checks: spec.checks?.length || 0, sourceStatus: sourceStatus, warnings: warnings, published: false }); }
      if (args.boardId && (!this.boards || (await this.boards.get(args.boardWorkspaceId || this.workspaceId, args.boardId)).archived)) { throw new Error('Select an available board'); }
      stage = 'publish';
      if (!previous || args.replaceData) { spec.data = testedData; }
      const record = await repository.publish(id, spec, path, this.threadId, !!previous, cancellation,
        { expectedRevision: previous?.configRevision, replaceData: args.replaceData, publicationKey: args.requestId, sourceVerified: sourceStatus === 'passed' });
      if (args.boardId) { await this.pinPublished(owner, id, args); }
      return JSON.stringify({ panelId: id, workspaceId: owner, title: record.definition.title, size: record.layout?.size || record.definition.size, configRevision: record.configRevision, published: true,
        openFrom: 'Life Panel', sourceStatus: sourceStatus, widths: widths, checks: spec.checks?.length || 0, warnings: warnings });
    } catch (error) {
      cancellation.check();
      if (error instanceof ToolFailure) { throw error; }
      throw new ToolFailure('PANEL_' + stage.toUpperCase() + '_FAILED', (error as Error).message, 'fix_' + stage + '_and_validate_again',
        { path: path, category: stage, result: error instanceof PanelTaskFailure ? error.info : undefined });
    }
  }
  private async pinPublished(owner: string, id: string, args: PublishPanelArguments): Promise<void> {
    try {
      if (!this.boards) { throw new Error('Board store is unavailable'); }
      await this.boards.pin(args.boardWorkspaceId || this.workspaceId, args.boardId!, { workspaceId: owner, panelId: id }, true);
    } catch (error) {
      throw new ToolFailure('PANEL_PIN_FAILED', 'Card published; pinning failed: ' + (error as Error).message, 'retry_same_request_id_or_manage_board',
        { result: { panelId: id, workspaceId: owner, published: true, pinned: false, boardId: args.boardId } as PanelPinResult } as ToolFailureDetails);
    }
  }
}
