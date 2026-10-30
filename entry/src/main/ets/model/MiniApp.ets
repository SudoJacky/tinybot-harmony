import { WebUiSpec, parseWebUi } from './WebUi';

export const MINI_APP_DIR: string = 'mini-apps';
export const MINI_APP_ICON_IDS: string[] = ['default', 'document', 'list', 'check', 'clock', 'folder', 'idea', 'star',
  'people', 'note', 'picture', 'tools', 'voice', 'audio', 'link', 'message'];
export const MINI_APP_ICON_COLOR_IDS: string[] = ['green', 'blue', 'orange', 'purple', 'rose'];
export function miniAppIconId(icon: string): string {
  if (!MINI_APP_ICON_IDS.includes(icon)) { throw new Error('Invalid mini app icon: ' + icon); }
  return icon;
}
export function miniAppIconColorId(color: string): string {
  if (!MINI_APP_ICON_COLOR_IDS.includes(color)) { throw new Error('Invalid mini app icon color: ' + color); }
  return color;
}
export interface MiniAppRecord {
  version: number; id: string; title: string; description: string; sourcePath: string; sourceThreadId: string;
  createdAt: number; updatedAt: number; lastOpenedAt: number; archived: boolean;
  page: WebUiSpec; previousPage?: WebUiSpec; icon?: string; iconColor?: string;
}
export interface MiniAppRevision {
  id: string; number: number; title: string; description: string; summary: string;
  sourcePath: string; sourceThreadId: string; createdAt: number; dataSchema: number; page: WebUiSpec;
}
export interface MiniAppAdoption { revisionId: string; adoptedAt: number; dataFile: string; }
export interface VersionedMiniAppRecord extends MiniAppRecord {
  currentRevisionId: string; dataFile: string; revisions: MiniAppRevision[]; adoptions: MiniAppAdoption[];
}
export interface MiniAppEntry { workspaceId: string; app: MiniAppRecord; }
export interface MiniAppSnapshot { value: Object | null; revision: string; }
// A native-owned capability. Generated pages never choose a workspace, app ID or path.
export interface MiniAppStorage {
  load(): Promise<MiniAppSnapshot>;
  save(value: Object | null, revision: string): Promise<MiniAppSnapshot>;
}
export function miniAppId(id: string): string {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/.test(id)) { throw new Error('Invalid mini app ID'); }
  return id;
}
export function miniAppPath(id: string, file: string): string { return MINI_APP_DIR + '/' + miniAppId(id) + '/' + file; }
export function parseMiniApp(text: string, id: string): MiniAppRecord {
  const app = JSON.parse(text) as MiniAppRecord;
  if (!app || ![1, 2].includes(app.version) || app.id !== miniAppId(id) || typeof app.title !== 'string' || !app.title.trim() || app.title.length > 160 ||
    typeof app.description !== 'string' || typeof app.sourcePath !== 'string' || typeof app.sourceThreadId !== 'string' ||
    typeof app.archived !== 'boolean' || ![app.createdAt, app.updatedAt, app.lastOpenedAt].every((time: number) => Number.isFinite(time) && time >= 0)) {
    throw new Error('Invalid mini app manifest: ' + id);
  }
  if (app.icon !== undefined) { miniAppIconId(app.icon); }
  if (app.iconColor !== undefined) { miniAppIconColorId(app.iconColor); }
  app.page = parseWebUi(JSON.stringify(app.page));
  if (app.previousPage) { app.previousPage = parseWebUi(JSON.stringify(app.previousPage)); }
  if (app.version === 2) {
    const history = app as VersionedMiniAppRecord;
    if (!Array.isArray(history.revisions) || !history.revisions.length || !Array.isArray(history.adoptions) ||
      typeof history.currentRevisionId !== 'string' || !validDataFile(history.dataFile)) { throw new Error('Invalid mini app history: ' + id); }
    const ids = new Set<string>();
    history.revisions.forEach((revision, index) => {
      if (!revision || typeof revision.id !== 'string' || !new RegExp('^v' + (index + 1) + '(-[A-Za-z0-9_-]+)?$').test(revision.id) ||
        revision.number !== index + 1 || ids.has(revision.id) || typeof revision.title !== 'string' || !revision.title.trim() || revision.title.length > 160 ||
        typeof revision.description !== 'string' || typeof revision.summary !== 'string' || typeof revision.sourcePath !== 'string' ||
        typeof revision.sourceThreadId !== 'string' || !Number.isFinite(revision.createdAt) || revision.createdAt < 0 ||
        !Number.isSafeInteger(revision.dataSchema) || revision.dataSchema < 1) { throw new Error('Invalid mini app revision: ' + id); }
      ids.add(revision.id); revision.page = parseWebUi(JSON.stringify(revision.page));
    });
    if (history.currentRevisionId && !ids.has(history.currentRevisionId)) { throw new Error('Missing current mini app revision: ' + id); }
    if (history.adoptions.some((adoption) => !adoption || !ids.has(adoption.revisionId) || !Number.isFinite(adoption.adoptedAt) ||
      adoption.adoptedAt < 0 || !validDataFile(adoption.dataFile))) { throw new Error('Invalid mini app adoption: ' + id); }
  }
  return app;
}
function validDataFile(file: string): boolean { return typeof file === 'string' && /^data(?:-[A-Za-z0-9_-]+)?\.json$/.test(file); }
export function miniAppDataFile(app: MiniAppRecord): string { return app.version === 2 ? (app as VersionedMiniAppRecord).dataFile : 'data.json'; }
export function miniAppInCollection(app: MiniAppRecord): boolean { return app.version === 1 || !!(app as VersionedMiniAppRecord).currentRevisionId; }
export function miniAppPreviousRevision(app: MiniAppRecord): MiniAppRevision | undefined {
  if (app.version !== 2) { return undefined; }
  const history = app as VersionedMiniAppRecord;
  const current = history.revisions.find((revision) => revision.id === history.currentRevisionId);
  const previous = history.adoptions.slice().reverse().find((adoption) => adoption.revisionId !== history.currentRevisionId);
  const revision = history.revisions.find((item) => item.id === previous?.revisionId);
  // The legacy rollback action only changes the page; it cannot migrate a data schema.
  return current && revision?.dataSchema === current.dataSchema ? revision : undefined;
}
export function miniAppCanRollback(app: MiniAppRecord): boolean { return app.version === 2 ? !!miniAppPreviousRevision(app) : !!app.previousPage; }
export function miniAppPage(path: string, source: string, library: string = 'none'): WebUiSpec {
  if (!/\.(js|html|svg)$/i.test(path)) { throw new Error('Mini apps require a .js, .html or .svg file'); }
  const script = /\.js$/i.test(path);
  return parseWebUi(JSON.stringify({ version: 1, html: script ? '' : source, js: script ? source : '',
    css: 'html,body{margin:0;width:100%;min-height:100%;}svg{max-width:100%;}', library: library, height: 600, autoHeight: false }));
}
