import { WorkspaceFiles } from './WorkspaceFiles';
import { Cancellation } from './Cancellation';
import { ToolFailure } from '../model/ToolFailure';
import { toolError } from '../model/Agent';

export interface SearchOptions { path: string; query?: string; glob?: string; ignoreCase?: boolean; context?: number; limit?: number; cursor?: string; }
interface SearchTask { path: string; directory: boolean; offset: number; version?: string; }
interface SearchState { key: string; tasks: SearchTask[]; }
interface SearchMatch { path: string; line: number; text: string; column: number; before: string[]; after: string[]; }
interface SkippedFile { path: string; reason: Object; }
let searchInstance: number = 0;

// Deliberately support globs, not arbitrary regexes. A basename pattern applies at every depth.
export function filePattern(pattern: string): RegExp {
  if (!pattern || pattern.length > 200 || pattern.includes('\\') || pattern.split('/').some((part: string) => part === '..')) {
    throw new ToolFailure('FS_INVALID_ARGUMENTS', 'Use a relative glob such as *.ts or docs/**/*.md.', 'fix_arguments');
  }
  let source = '';
  for (let i = 0; i < pattern.length; i++) {
    const char = pattern[i];
    if (char === '*' && pattern[i + 1] === '*') {
      i++;
      if (pattern[i + 1] === '/') { i++; source += '(?:.*/)?'; } else { source += '.*'; }
    } else if (char === '*') { source += '[^/]*'; }
    else if (char === '?') { source += '[^/]'; }
    else { source += /[.()+^$|{}\[\]]/.test(char) ? '\\' + char : char; }
  }
  return new RegExp((pattern.includes('/') ? '^' : '(?:^|/)') + source + '$');
}

export class WorkspaceSearch {
  private files: WorkspaceFiles;
  private cursors: Map<string, SearchState> = new Map<string, SearchState>();
  private serial: number = 0;
  private prefix: string = Date.now().toString(36) + '-' + (++searchInstance);
  constructor(files: WorkspaceFiles) { this.files = files; }

  async execute(find: boolean, args: SearchOptions, cancellation: Cancellation): Promise<string> {
    const limit = args.limit === undefined ? 100 : args.limit;
    const context = args.context === undefined ? 0 : args.context;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100 || !Number.isInteger(context) || context < 0 || context > 5 ||
      (args.ignoreCase !== undefined && typeof args.ignoreCase !== 'boolean') ||
      (args.cursor !== undefined && typeof args.cursor !== 'string') || (args.glob !== undefined && typeof args.glob !== 'string') ||
      (!find && (typeof args.query !== 'string' || !args.query || args.query.length > 1000))) {
      throw new ToolFailure('FS_INVALID_ARGUMENTS', 'Use limit 1–100, context 0–5 and a nonempty query for content searches.', 'fix_arguments', { path: args.path });
    }
    const pattern = filePattern(args.glob || '*');
    const key = JSON.stringify({ find: find, path: args.path, query: args.query || '', glob: args.glob || '*', ignoreCase: args.ignoreCase === true, context: context, limit: limit });
    let tasks: SearchTask[] = [{ path: args.path, directory: true, offset: 0 }];
    if (args.cursor !== undefined) {
      const saved = this.cursors.get(args.cursor);
      if (!saved || saved.key !== key) { throw new ToolFailure('FS_INVALID_CURSOR', 'Search cursor expired or parameters changed. Restart without cursor.', 'restart_search', { path: args.path }); }
      tasks = saved.tasks.map((item: SearchTask): SearchTask => ({ path: item.path, directory: item.directory, offset: item.offset, version: item.version }));
    }
    const matches: SearchMatch[] = []; const paths: string[] = []; const skipped: string[] = []; const skippedDetails: SkippedFile[] = [];
    let checked = 0; let directories = 0;
    const needle = args.ignoreCase ? (args.query || '').toLowerCase() : args.query || '';
    while (tasks.length && checked < 200 && directories < 100 && (find ? paths.length : matches.length) < limit) {
      cancellation.check(); const task = tasks.shift()!;
      if (task.directory) {
        directories++;
        const page = await this.files.list(task.path, cancellation, task.offset);
        if (page.truncated && (page.nextOffset === undefined || page.nextOffset <= task.offset)) {
          throw new ToolFailure('FS_INCOMPLETE_LIST', 'Directory listing cannot continue.', 'inspect_directory', { path: task.path });
        }
        // Keep directory continuation after its entries, without dropping any remainder at a page boundary.
        if (page.nextOffset !== undefined) { tasks.push({ path: task.path, directory: true, offset: page.nextOffset }); }
        for (const entry of page.entries) {
          if (entry.name.startsWith('.') || !['directory', 'file'].includes(entry.kind)) { continue; }
          const path = (task.path ? task.path + '/' : '') + entry.name;
          const relative = args.path ? path.slice(args.path.length + 1) : path;
          if (entry.kind === 'directory' || pattern.test(relative)) { tasks.push({ path: path, directory: entry.kind === 'directory', offset: 0 }); }
        }
        continue;
      }
      checked++;
      if (find) { paths.push(task.path); continue; }
      let content: string; let version: string;
      try { const file = await this.files.read(task.path, cancellation); content = file.content; version = file.version; }
      catch (error) {
        cancellation.check(); if (task.version !== undefined) { throw error as Error; }
        skipped.push(task.path); skippedDetails.push({ path: task.path, reason: JSON.parse(toolError(error as Error)) as Object }); continue;
      }
      if (task.version !== undefined && task.version !== version) { throw new ToolFailure('FS_STALE_SEARCH', 'File changed while paging search results. Restart the search.', 'restart_search', { path: task.path }); }
      const lines = content.split('\n');
      let line = task.offset;
      for (; line < lines.length && matches.length < limit; line++) {
        const position = (args.ignoreCase ? lines[line].toLowerCase() : lines[line]).indexOf(needle);
        if (position < 0) { continue; }
        let column = Math.max(0, position - 100);
        if (column > 0 && /[\uDC00-\uDFFF]/.test(lines[line][column])) { column--; }
        matches.push({ path: task.path, line: line + 1, column: column + 1, text: lines[line].slice(column, column + 600),
          before: lines.slice(Math.max(0, line - context), line).map((value: string) => value.slice(0, 600)),
          after: lines.slice(line + 1, line + context + 1).map((value: string) => value.slice(0, 600)) });
      }
      if (line < lines.length) { tasks.unshift({ path: task.path, directory: false, offset: line, version: version }); }
    }
    cancellation.check();
    let cursor: string | undefined = undefined;
    if (tasks.length) {
      cursor = 'search-' + this.prefix + '-' + (++this.serial);
      this.cursors.set(cursor, { key: key, tasks: tasks });
      // Cursors retain traversal positions, never file contents. The latest 32 pages can be replayed.
      if (this.cursors.size > 32) { this.cursors.delete(Array.from(this.cursors.keys())[0]); }
    }
    return find ? JSON.stringify({ paths: paths, checkedFiles: checked, truncated: tasks.length > 0, nextCursor: cursor }) :
      JSON.stringify({ matches: matches, skipped: skipped, skippedDetails: skippedDetails,
        reductions: matches.length ? ['Search results contain excerpts of up to 600 characters per line. Use read_file for complete source before editing.'] : [],
        checkedFiles: checked, truncated: tasks.length > 0, nextCursor: cursor });
  }
}
