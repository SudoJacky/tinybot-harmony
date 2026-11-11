import { ToolCall, ToolDefinition, ToolProperty } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { ToolFailure, ToolFailureDetails, parseToolArguments } from '../model/ToolFailure';
import { LifePanels } from './LifePanels';
import { providerBalanceCatalog } from './ProviderBalanceCatalog';
import { panelId, parsePanelSpec, PanelListQuery, PanelSpec } from '../model/LifePanel';
import { panelSkillCatalog } from '../model/PanelSkillCatalog';
import { webUiPage, WebUiStorage, WebUiSnapshot, WebUiPanelContext } from '../model/WebUi';
import { PanelValidationStorage } from './PanelValidationStorage';
import { PanelProbeOptions, PanelInputs, reconcilePanelInputs } from '../model/PanelContract';
import { PanelTaskFailure } from './PanelTaskFailure';
import { getLocale } from '../model/I18n';
import { WorkspaceFiles } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';
import { Cancellation } from './Cancellation';
import { LifeBoards } from './LifeBoards';
import { BoardItem, BoardEntry, boardLayoutKey, boardLayoutItems } from '../model/LifeBoard';
import { GridRect, validateGridRect, gridPixels } from '../model/PanelGrid';
import { PanelRect } from '../model/PanelPresentation';
import { panelReference } from '../model/PublishedPanel';
interface PanelEvidence { schema?: string; webRuntime?: string; layout?: string; screenshot: string; visualReview: string; }
interface BoardInspectionItem { mountId?: string; workspaceId: string; panelId: string; x: number; y: number; w: number; h: number; rendered?: PanelRect; }
interface PanelRevisionResult { configRevision: number; }
interface PanelPinResult { panelId: string; workspaceId: string; published: boolean; pinned: boolean; boardId?: string; }
interface PublishPanelArguments { path?: string; htmlPath?: string; panelId?: string; workspaceId?: string; boardId?: string; boardWorkspaceId?: string; action?: string; title?: string; description?: string; items?: BoardItem[]; layout?: GridRect; panelWorkspaceId?: string; section?: string; requestId?: string; expectedRevision?: number; replaceData?: boolean; checkSource?: boolean; viewportWidth?: number; placementWidth?: number; placementHeight?: number; inputs?: PanelInputs; }
export class LifePanelTools implements AgentTools {
  private panels: LifePanels;
  private workspaceId: string;
  private threadId: string;
  private files: WorkspaceFiles;
  private boards?: LifeBoards;
  private validate?: (page: string, storage: WebUiStorage, context: WebUiPanelContext, cancellation: Cancellation, options?: PanelProbeOptions) => Promise<void>;
  constructor(panels: LifePanels, workspaceId: string, threadId: string, files: WorkspaceFiles, boards?: LifeBoards,
    validate?: (page: string, storage: WebUiStorage, context: WebUiPanelContext, cancellation: Cancellation, options?: PanelProbeOptions) => Promise<void>) {
    this.panels = panels; this.workspaceId = workspaceId; this.threadId = threadId; this.files = files;
    this.boards = boards;
    this.validate = validate;
  }
  definitions(): ToolDefinition[] {
    return [
      { type: 'function', function: { name: 'get_life_panel_catalog', description: 'Return Skill resource names/paths for read_skill; section:balance returns configured provider accounts and a matching card definition. Native mail HTML supports await tinybot.panel.readMail({uidValidity,uid}) -> {message,text}, using the saved source.mail account/folder and mailbox body permission. Retain UID fields, render textContent, and call on a user action in a foreground card; preview/preflight cannot read mail. This API supersedes older Skill text saying only headers are available. Agent sources are for model summaries/extraction, not direct body display.', parameters: { type: 'object', properties: { 'section': { type: 'string', enum: ['all', 'html', 'native', 'sources', 'balance', 'design'], description: 'Requested resource section; defaults to all' } }, required: [], additionalProperties: false } } },
      { type: 'function', function: { name: 'list_life_panels', description: 'Return compact card summaries and nextCursor. Optional workspace/archived filters; get_life_panel reads full details.', parameters: { type: 'object', properties: {
        'workspaceId': { type: 'string', description: 'Optional owner workspace filter' }, 'archived': { type: 'boolean', description: 'False by default; true lists archived cards' },
        'limit': { type: 'integer', description: '1–20 summaries, default 10; at most 50 manifests are read per page' }, 'cursor': { type: 'string', description: 'nextCursor from the same filters' }
      }, required: [], additionalProperties: false } } },
      { type: 'function', function: { name: 'get_life_panel', description: 'Read a card by owner workspaceId/panelId; section selects definition, data, task or all. Returns reference: optionally copy it on its own line in the final answer to show this card there; otherwise no chat card is shown.', parameters: { type: 'object', properties: {
        'workspaceId': { type: 'string', description: 'Owner workspace ID' }, 'panelId': { type: 'string', description: 'Card ID' },
        'section': { type: 'string', enum: ['all', 'definition', 'data', 'task'], description: 'Requested detail section' }
      }, required: ['workspaceId', 'panelId'], additionalProperties: false } } },
      this.publicationTool(false), this.publicationTool(true),
      { type: 'function', function: { name: 'list_life_boards', description: 'List boards and their saved card references.', parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } },
      { type: 'function', function: { name: 'get_life_board', description: 'Read board references, mountIds and grid layout as JSON. Optional viewportWidth computes rendered rectangles in vp; no screenshot is returned. Optionally copy the returned reference on its own line in the final answer to show the board.', parameters: { type: 'object', properties: {
        'workspaceId': { type: 'string', description: 'Board owner workspace' }, 'boardId': { type: 'string', description: 'Board ID' },
        'viewportWidth': { type: 'number', minimum: 160, maximum: 1200, description: 'Actual board content width in vp; omit if unknown, do not assume desktop width' }
      }, required: ['workspaceId', 'boardId'], additionalProperties: false } } },
      { type: 'function', executionMode: 'sequential', function: { name: 'manage_life_board', description: 'save creates/updates a board; supplied items replaces its layout. place mounts/moves one existing card using panelId, panelWorkspaceId and layout, pushing collisions down. Board layouts automatically compact upward, retaining horizontal positions and sizes; requested y may settle higher. archive/restore changes board availability. No automatic chat display; optionally copy the returned reference on its own line in the final answer to show the board.', parameters: { type: 'object', properties: {
        'action': { type: 'string', enum: ['save', 'place', 'archive', 'restore'], description: 'Board operation' }, 'boardId': { type: 'string', description: 'Existing board ID' }, 'workspaceId': { type: 'string', description: 'Board owner; defaults to current' }, 'title': { type: 'string', description: 'Required name for a new board' }, 'description': { type: 'string', description: 'Optional description' }, 'items': { type: 'array', description: 'Optional complete grid layout', items: { type: 'object', description: 'Card reference', properties: { 'workspaceId': { type: 'string', description: 'Card owner' }, 'panelId': { type: 'string', description: 'Shared card ID' }, 'x': { type: 'integer', minimum: 0, maximum: 10, description: 'Left column' }, 'y': { type: 'integer', minimum: 0, description: 'Top row' }, 'w': { type: 'integer', minimum: 2, maximum: 12, description: 'Width in cells' }, 'h': { type: 'integer', minimum: 2, maximum: 33, description: 'Height in cells (32vp rows, 12vp gaps)' } }, required: ['workspaceId', 'panelId', 'x', 'y', 'w', 'h'], additionalProperties: false } },
         'panelId': { type: 'string', description: 'Card ID for place' }, 'panelWorkspaceId': { type: 'string', description: 'Card owner for place' },
        'layout': { type: 'object', description: 'Placement for one card; other cards are retained', properties: {
          'x': { type: 'integer', minimum: 0, maximum: 10, description: 'Left column' }, 'y': { type: 'integer', minimum: 0, description: 'Top row' },
          'w': { type: 'integer', minimum: 2, maximum: 12, description: 'Width in columns' }, 'h': { type: 'integer', minimum: 2, maximum: 33, description: 'Height in rows' }
        }, required: ['x', 'y', 'w', 'h'], additionalProperties: false }
      }, required: ['action'], additionalProperties: false } } },
      { type: 'function', executionMode: 'sequential', function: { name: 'manage_life_panel_task', description: 'Pause/resume automatic updates or manually refresh an existing card by owner workspaceId/panelId.', parameters: { type: 'object', properties: { 'panelId': { type: 'string', description: 'Card ID' }, 'workspaceId': { type: 'string', description: 'Card owner' }, 'action': { type: 'string', enum: ['pause', 'resume', 'refresh'], description: 'Task operation' }, 'inputs': { type: 'object', description: 'Optional declared input values for a manual refresh, merged with current inputs', additionalProperties: true } }, required: ['panelId', 'workspaceId', 'action'], additionalProperties: false } } }
    ];
  }
  private publicationTool(validateOnly: boolean): ToolDefinition {
    const properties: Record<string, ToolProperty> = {
      'path': { type: 'string', description: 'Current workspace .panel.json path' },
      'htmlPath': { type: 'string', description: 'Self-contained HTML; optional when view is embedded. Uses definition view height if supplied, otherwise 320.' },
      'panelId': { type: 'string', description: 'Existing card ID for update/validation against saved user state.' },
      'workspaceId': { type: 'string', description: 'Existing card owner, defaults to current workspace.' },
      'expectedRevision': { type: 'integer', description: 'Required for updates: configRevision from get_life_panel. Rejects stale edits.', minimum: 1 },
      'replaceData': { type: 'boolean', description: 'False by default: preserve current live data on updates. True explicitly replaces it with the tested source/initial snapshot.' },
      'checkSource': { type: 'boolean', description: 'Default true: run configured source without persisting. False explicitly defers connection/source setup and is reported as not_checked.' },
      'placementWidth': { type: 'number', minimum: 32, maximum: 1200, description: 'Chosen placement width in vp; pair with placementHeight to validate just this viewport' },
      'placementHeight': { type: 'number', minimum: 76, maximum: 1440, description: 'Chosen placement height in vp; pair with placementWidth' },
      'viewportWidth': { type: 'integer', description: 'Full-card width in vp from board context, 160–1200; checks run here and half width.', minimum: 160, maximum: 1200 }
    };
    if (!validateOnly) {
      properties['requestId'] = { type: 'string', description: 'Stable unique identifier (letters/digits/-/_, up to 64) for one new-card intent. Retrying reuses its card; to edit use panelId + expectedRevision.' };
      properties['boardId'] = { type: 'string', description: 'Board to pin into after publication' };
      properties['boardWorkspaceId'] = { type: 'string', description: 'Board owner workspace' };
    }
    return { type: 'function', executionMode: 'sequential',
      function: { name: validateOnly ? 'validate_life_panel' : 'publish_life_panel',
        description: validateOnly ? 'Validate a candidate without saving: definition, source and HTML checks at supplied placement dimensions (otherwise half/full viewportWidth). Returns JSON diagnostics; uses detached state.' :
          'Validate and save a card, optionally pinning it to boardId. Updates require panelId and expectedRevision; new-card requestId deduplicates retries. Live data is preserved unless replaceData:true. No automatic chat display; optionally copy the returned reference verbatim on its own line outside code fences in the final answer to show the card there.',
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
      const reference = panelReference({ workspaceId: args.workspaceId, panelId: panel.id });
      if (!args.section || args.section === 'all') { return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, title: panel.definition.title, reference: reference, panel: panel }); }
      if (args.section === 'definition') { return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, title: panel.definition.title, reference: reference, definition: panel.definition, layout: panel.layout, configRevision: panel.configRevision }); }
      if (args.section === 'data') { return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, title: panel.definition.title, reference: reference, data: panel.data, user: panel.user, viewState: panel.viewState, inputs: panel.inputs, refreshedAt: panel.refreshedAt }); }
      return JSON.stringify({ workspaceId: args.workspaceId, panelId: panel.id, title: panel.definition.title, reference: reference, paused: panel.paused, runs: panel.runs || [], error: panel.error, runtimeError: panel.runtimeError, running: this.panels.repository(args.workspaceId).isRefreshing(panel.id) });
    }
    if (call.function.name === 'get_life_board') {
      if (!this.boards || Object.keys(args).some((key: string) => !['workspaceId', 'boardId', 'viewportWidth'].includes(key)) ||
        typeof args.workspaceId !== 'string' || typeof args.boardId !== 'string' || args.viewportWidth !== undefined &&
        (!Number.isFinite(args.viewportWidth) || args.viewportWidth < 160 || args.viewportWidth > 1200)) { throw new Error('Provide a board reference and optional actual viewportWidth (160–1200vp)'); }
      const board = await this.boards.get(args.workspaceId, args.boardId);
      return JSON.stringify({ workspaceId: args.workspaceId, boardId: board.id, title: board.title, reference: panelReference({ workspaceId: args.workspaceId, boardId: board.id }), archived: board.archived,
        viewportWidth: args.viewportWidth, evidence: { layout: 'saved_rectangles', screenshot: 'not_provided', visualReview: 'not_performed' } as PanelEvidence,
        items: board.items.map((item: BoardItem): BoardInspectionItem => ({ mountId: item.mountId, workspaceId: item.workspaceId, panelId: item.panelId,
          x: item.x, y: item.y, w: item.w, h: item.h, rendered: args.viewportWidth === undefined ? undefined : gridPixels(item, args.viewportWidth) })) });
    }
    if (['get_life_panel_catalog', 'list_life_boards'].includes(call.function.name)) {
      if (Object.keys(args).some((key: string) => call.function.name !== 'get_life_panel_catalog' || key !== 'section')) { throw new ToolFailure('INVALID_ARGUMENTS', 'Unexpected catalog/list arguments', 'fix_arguments'); }
      if (call.function.name === 'get_life_panel_catalog') { return args.section === 'balance' ? providerBalanceCatalog() : panelSkillCatalog(args.section); }
      if (call.function.name === 'list_life_boards') { if (!this.boards) { throw new Error('Board store is unavailable'); } return JSON.stringify((await this.boards.list()).map((entry: BoardEntry): BoardEntry => { entry.board.items = boardLayoutItems(entry.board.items); return entry; })); }
    }
    if (call.function.name === 'manage_life_panel_task') {
      if (args.inputs !== undefined && args.action !== 'refresh') { throw new Error('inputs requires action refresh'); }
      if (Object.keys(args).some((key) => !['panelId', 'workspaceId', 'action', 'inputs'].includes(key)) || typeof args.panelId !== 'string' || typeof args.workspaceId !== 'string' || !['pause', 'resume', 'refresh'].includes(args.action || '')) { throw new Error('Invalid card task operation'); }
      const repository = this.panels.repository(args.workspaceId);
      return JSON.stringify(args.action === 'refresh' ? await repository.refresh(args.panelId, cancellation, 'manual', args.inputs) : await repository.pause(args.panelId, args.action === 'pause'));
    }
    if (call.function.name === 'manage_life_board') {
      if (!this.boards) { throw new Error('Board store is unavailable'); }
      if (Object.keys(args).some((key) => !['action', 'boardId', 'workspaceId', 'title', 'description', 'items', 'panelId', 'panelWorkspaceId', 'layout'].includes(key)) || !['save', 'place', 'archive', 'restore'].includes(args.action || '') ||
        (args.workspaceId !== undefined && typeof args.workspaceId !== 'string') || (args.boardId !== undefined && typeof args.boardId !== 'string') || (args.title !== undefined && typeof args.title !== 'string') || (args.description !== undefined && typeof args.description !== 'string')) { throw new Error('Invalid board operation'); }
      if (args.items !== undefined && (!Array.isArray(args.items) || args.items.some((item: BoardItem) => !item || Object.keys(item).some((key: string) => !['workspaceId', 'panelId', 'x', 'y', 'w', 'h'].includes(key))))) { throw new Error('Board layout items accept only references and rectangles'); }
      const owner = args.workspaceId || this.workspaceId;
      if (!args.boardId && owner !== this.workspaceId) { throw new Error('Create boards in the current workspace'); }
      const before = args.boardId ? await this.boards.get(owner, args.boardId) : undefined;
      if (args.action !== 'save' && !before) { throw new Error('Select an existing board'); }
      if (args.action === 'place') {
        if (!before || typeof args.panelId !== 'string' || typeof args.panelWorkspaceId !== 'string' || !args.layout ||
          args.items !== undefined || args.title !== undefined || args.description !== undefined ||
          Object.keys(args.layout).some((key: string) => !['x', 'y', 'w', 'h'].includes(key))) { throw new Error('Place requires a card reference and one grid rectangle'); }
        validateGridRect(args.layout);
        const placed = await this.boards.place(owner, before.id, { workspaceId: args.panelWorkspaceId, panelId: args.panelId }, args.layout, boardLayoutKey(before.items));
        return JSON.stringify({ boardId: placed.id, workspaceId: owner, title: placed.title, reference: panelReference({ workspaceId: owner, boardId: placed.id }), items: boardLayoutItems(placed.items), openFrom: 'Life Panel' });
      }
      if (args.layout !== undefined || args.panelId !== undefined || args.panelWorkspaceId !== undefined) { throw new Error('Placement fields require action:place'); }
      const board = await this.boards.save(owner, args.boardId || '', args.title === undefined ? before?.title || '' : args.title,
        args.description === undefined ? before?.description || '' : args.description, args.items, args.action === 'save' ? undefined : args.action === 'archive');
      return JSON.stringify({ boardId: board.id, workspaceId: owner, title: board.title, reference: panelReference({ workspaceId: owner, boardId: board.id }), openFrom: 'Life Panel' });
    }
    if (!['publish_life_panel', 'validate_life_panel'].includes(call.function.name)) { throw new ToolFailure('TOOL_UNAVAILABLE', 'Unknown Life Panel tool', 'check_available_tools'); }
    const validating = call.function.name === 'validate_life_panel';
    if (validating && [args.requestId, args.boardId, args.boardWorkspaceId].some((value: string | undefined) => value !== undefined)) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Validation does not accept publication or pinning arguments', 'remove_publication_arguments');
    }
    if (Object.keys(args).some((key: string) => !['path', 'htmlPath', 'panelId', 'workspaceId', 'boardId', 'boardWorkspaceId', 'requestId', 'expectedRevision', 'replaceData', 'checkSource', 'viewportWidth', 'placementWidth', 'placementHeight'].includes(key)) || typeof args.path !== 'string' || !args.path.endsWith('.panel.json') ||
      [args.panelId, args.workspaceId, args.boardId, args.boardWorkspaceId].some((value: string | undefined) => value !== undefined && typeof value !== 'string') ||
      [args.replaceData, args.checkSource].some((value: boolean | undefined) => value !== undefined && typeof value !== 'boolean') ||
      args.requestId !== undefined && (typeof args.requestId !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(args.requestId)) ||
      args.viewportWidth !== undefined && (!Number.isInteger(args.viewportWidth) || args.viewportWidth < 160 || args.viewportWidth > 1200)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Invalid card validation/publication arguments', 'fix_arguments'); }
    if ((args.placementWidth === undefined) !== (args.placementHeight === undefined) ||
      args.placementWidth !== undefined && (!Number.isFinite(args.placementWidth) || args.placementWidth < 32 || args.placementWidth > 1200 ||
        !Number.isFinite(args.placementHeight) || args.placementHeight! < 76 || args.placementHeight! > 1440)) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Provide both placementWidth (32–1200vp) and placementHeight (76–1440vp)', 'fix_placement_size');
    }
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
        definition.view = webUiPage(args.htmlPath, (await this.files.read(workspaceRelativePath(args.htmlPath, false), cancellation)).content); definition.view.height = height;
      }
      const spec = parsePanelSpec(JSON.stringify(definition));
      if (spec.view && (!spec.dataSchema || !spec.checks)) { throw new ToolFailure('PANEL_CONTRACT_REQUIRED', 'HTML authoring requires dataSchema and checks (use [] for display-only cards); read_skill widget references/validation.md', 'add_schema_and_interaction_checks', { path: path }); }
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
      const widths: number[] = spec.view ? args.placementWidth !== undefined ? [args.placementWidth] : [Math.max(160, Math.round(((args.viewportWidth || 360) - 12) / 2)), args.viewportWidth || 360] : [];
      stage = 'render';
      if (spec.view) {
        if (!this.validate) { throw new Error('Interactive card validation is unavailable'); }
        const context: WebUiPanelContext = { data: testedData, inputs: inputs, title: spec.title, status: 'ready', canRefresh: !!spec.source, locale: getLocale() };
        for (const width of widths) {
          const storage = new PanelValidationStorage(previous?.viewState || { value: null, revision: 'initial' });
          try {
            await this.validate(JSON.stringify(spec.view), storage, context, cancellation, { width: width, height: args.placementHeight, checks: spec.checks || [] });
            // Reopen with the state produced by the interaction checks, without replaying them.
            if (spec.checks?.length) { await this.validate(JSON.stringify(spec.view), storage, context, cancellation, { width: width, height: args.placementHeight, checks: [] }); }
          } catch (error) { throw new Error('width=' + width + ': ' + (error as Error).message); }
        }
        if (previous && !args.replaceData && JSON.stringify(testedData) !== JSON.stringify(retained)) {
          await this.validate(JSON.stringify(spec.view), new PanelValidationStorage(previous.viewState || { value: null, revision: 'initial' }),
            { data: retained, inputs: inputs, title: spec.title, status: 'ready', canRefresh: !!spec.source, locale: getLocale() }, cancellation, { width: args.placementWidth || args.viewportWidth || 360, height: args.placementHeight, checks: [] });
        }
      }
      const warnings: string[] = [];
      if (spec.view && !spec.dataSchema) { warnings.push('No dataSchema: HTML task output shape is not enforced. Add an explicit schema.'); }
      if (spec.view && !spec.checks?.length) { warnings.push('No interaction checks declared: only startup/layout/labels checked.'); }
      if (args.checkSource === false && spec.source) { warnings.push('Source was explicitly not checked; connection/setup remains pending.'); }
      const evidence: PanelEvidence = { schema: spec.dataSchema ? 'passed' : 'not_declared', webRuntime: spec.view ? 'passed' : 'not_applicable', screenshot: 'not_provided', visualReview: 'not_performed' };
      const sourceStatus = spec.source ? args.checkSource === false ? 'not_checked' : 'passed' : 'not_applicable';
      if (validating) { return JSON.stringify({ valid: true, evidence: evidence, widths: widths, height: args.placementHeight, checks: spec.checks?.length || 0, sourceStatus: sourceStatus, warnings: warnings, published: false }); }
      if (args.boardId && (!this.boards || (await this.boards.get(args.boardWorkspaceId || this.workspaceId, args.boardId)).archived)) { throw new Error('Select an available board'); }
      stage = 'publish';
      if (!previous || args.replaceData) { spec.data = testedData; }
      const record = await repository.publish(id, spec, path, this.threadId, !!previous, cancellation,
        { expectedRevision: previous?.configRevision, replaceData: args.replaceData, publicationKey: args.requestId, sourceVerified: sourceStatus === 'passed' });
      if (args.boardId) { await this.pinPublished(owner, id, args); }
      return JSON.stringify({ panelId: id, workspaceId: owner, title: record.definition.title, reference: panelReference({ workspaceId: owner, panelId: id }), size: record.layout?.size || record.definition.size, configRevision: record.configRevision, published: true,
        openFrom: 'Life Panel', evidence: evidence, sourceStatus: sourceStatus, height: args.placementHeight, widths: widths, checks: spec.checks?.length || 0, warnings: warnings });
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
