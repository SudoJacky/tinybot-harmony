import { WebUiSpec, parseWebUi } from './WebUi';

export const MINI_APP_DIR: string = 'mini-apps';
export interface MiniAppRecord {
  version: number; id: string; title: string; description: string; sourcePath: string; sourceThreadId: string;
  createdAt: number; updatedAt: number; lastOpenedAt: number; archived: boolean;
  page: WebUiSpec; previousPage?: WebUiSpec;
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
  if (!app || app.version !== 1 || app.id !== miniAppId(id) || typeof app.title !== 'string' || !app.title.trim() || app.title.length > 160 ||
    typeof app.description !== 'string' || typeof app.sourcePath !== 'string' || typeof app.sourceThreadId !== 'string' ||
    typeof app.archived !== 'boolean' || ![app.createdAt, app.updatedAt, app.lastOpenedAt].every((time: number) => Number.isFinite(time) && time >= 0)) {
    throw new Error('Invalid mini app manifest: ' + id);
  }
  app.page = parseWebUi(JSON.stringify(app.page));
  if (app.previousPage) { app.previousPage = parseWebUi(JSON.stringify(app.previousPage)); }
  return app;
}
export function miniAppPage(path: string, source: string, library: string = 'none'): WebUiSpec {
  if (!/\.(js|html|svg)$/i.test(path)) { throw new Error('Mini apps require a .js, .html or .svg file'); }
  const script = /\.js$/i.test(path);
  return parseWebUi(JSON.stringify({ version: 1, html: script ? '' : source, js: script ? source : '',
    css: 'html,body{margin:0;width:100%;min-height:100%;}svg{max-width:100%;}', library: library, height: 600, autoHeight: false }));
}
