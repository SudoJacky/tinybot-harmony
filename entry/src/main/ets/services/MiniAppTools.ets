import { ToolCall, ToolDefinition } from '../model/Agent';
import { AgentTools } from './AgentLoop';
import { ToolFailure, parseToolArguments } from '../model/ToolFailure';
import { MiniApps, MiniAppValidationStorage } from './MiniApps';
import { MiniAppStorage, MiniAppSnapshot, miniAppId, miniAppPage, miniAppPath } from '../model/MiniApp';
import { WorkspaceFiles } from './WorkspaceFiles';
import { workspaceRelativePath } from './WorkspaceTools';
import { Cancellation } from './Cancellation';

interface PublishArguments { path: string; title: string; description?: string; appId?: string; library?: string; }
interface AppSummary { appId: string; title: string; description: string; archived: boolean; sourcePath: string; dataPath: string; updatedAt: number; }
export class MiniAppTools implements AgentTools {
  private apps: MiniApps;
  private workspaceId: string;
  private threadId: string;
  private files: WorkspaceFiles;
  private validate: (page: string, storage: MiniAppStorage, cancellation: Cancellation) => Promise<void>;
  constructor(apps: MiniApps, workspaceId: string, threadId: string, files: WorkspaceFiles,
    validate: (page: string, storage: MiniAppStorage, cancellation: Cancellation) => Promise<void>) {
    this.apps = apps; this.workspaceId = workspaceId; this.threadId = threadId; this.files = files; this.validate = validate;
  }
  definitions(): ToolDefinition[] {
    const listing: ToolDefinition = { type: 'function', function: { name: 'list_mini_apps', description: 'List local mini apps in this workspace, including stable app IDs, source and data paths. Use before updating an existing app.',
      parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } };
    const publish: ToolDefinition = { type: 'function', executionMode: 'sequential', function: { name: 'publish_mini_app',
        description: 'Create or update a persistent local mini app from a self-contained .js, .html or .svg workspace file. ' +
          'Use for reusable apps such as a ledger or habit tracker. Pass the existing appId to update without replacing user data. ' +
          'JavaScript runs in isolated ArkWeb with DOM/Canvas and optional THREE/OrbitControls; no imports, network, filesystem or localStorage. ' +
          'Use const snapshot = await tinybot.storage.load(); it returns {value, revision}, initially value=null. ' +
          'On user interaction, await tinybot.storage.save(nextValue, snapshot.revision); retain the returned snapshot/revision. ' +
          'Only show saved after fulfillment; catch errors visibly. A stale revision rejects: reload and reconcile, never blindly overwrite. ' +
          'Do not save during initialization. Never overwrite mini-apps/*/data.json when updating a page. ' +
          'Startup is checked against a read-only data snapshot before publication. The app then appears in the Mini apps collection; tell the user to open it there. ' +
          'Use publish_preview for temporary visuals that do not need storage.',
        parameters: { type: 'object', properties: {
          'path': { type: 'string', description: 'Workspace source path' }, 'title': { type: 'string', description: 'App name, 1–160 characters' },
          'description': { type: 'string', description: 'Short purpose of the app' }, 'appId': { type: 'string', description: 'Existing stable ID when updating; omit to create' },
          'library': { type: 'string', enum: ['none', 'three'], description: 'Optional preloaded library' }
        }, required: ['path', 'title'], additionalProperties: false } } };
    return [listing, publish];
  }
  async execute(call: ToolCall, cancellation: Cancellation): Promise<string> {
    const args = parseToolArguments(call.function.arguments) as PublishArguments;
    if (!args || typeof args !== 'object' || Array.isArray(args)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Expected an object', 'fix_arguments'); }
    cancellation.check();
    if (call.function.name === 'list_mini_apps') {
      if (Object.keys(args).length) { throw new ToolFailure('INVALID_ARGUMENTS', 'No arguments expected', 'fix_arguments'); }
      return JSON.stringify((await this.apps.list(this.workspaceId)).map((entry): AppSummary => ({ appId: entry.app.id, title: entry.app.title,
        description: entry.app.description, archived: entry.app.archived, sourcePath: entry.app.sourcePath,
        dataPath: miniAppPath(entry.app.id, 'data.json'), updatedAt: entry.app.updatedAt })));
    }
    if (call.function.name !== 'publish_mini_app') { throw new ToolFailure('TOOL_UNAVAILABLE', 'Unknown mini app tool', 'check_available_tools'); }
    if (Object.keys(args).some((key) => !['path', 'title', 'description', 'appId', 'library'].includes(key)) ||
      typeof args.path !== 'string' || typeof args.title !== 'string' || !args.title.trim() || args.title.length > 160 ||
      (args.description !== undefined && (typeof args.description !== 'string' || args.description.length > 1000)) ||
      (args.appId !== undefined && typeof args.appId !== 'string') || (args.library !== undefined && !['none', 'three'].includes(args.library))) {
      throw new ToolFailure('INVALID_ARGUMENTS', 'Expected path, title and optional description, appId, library', 'fix_arguments');
    }
    const path = workspaceRelativePath(args.path, false), id = args.appId === undefined ? this.apps.createId() : miniAppId(args.appId);
    const repository = this.apps.repository(this.workspaceId);
    const data: MiniAppSnapshot = args.appId === undefined ? { value: null, revision: 'initial' } : await repository.load(id);
    const source = await this.files.read(path, cancellation), page = miniAppPage(path, source.content, args.library);
    await this.validate(JSON.stringify(page), new MiniAppValidationStorage(data), cancellation);
    cancellation.check();
    const app = await repository.publish(id, args.title.trim(), args.description || '', path, this.threadId, page, args.appId !== undefined, cancellation);
    return JSON.stringify({ appId: app.id, title: app.title, published: true, updated: args.appId !== undefined,
      sourcePath: app.sourcePath, dataPath: miniAppPath(app.id, 'data.json'), startup: 'passed', interaction: 'not_checked', openFrom: 'Mini apps collection' });
  }
}
