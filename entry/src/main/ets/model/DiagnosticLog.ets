export type LogLevel = 'debug' | 'info' | 'warn' | 'error';
export const LOG_LEVELS: LogLevel[] = ['debug', 'info', 'warn', 'error'];
export type LogValue = string | number | boolean;
export interface LogFields {
  change?: string; commonMessages?: number; sharedCharacters?: number; systemHash?: number; toolsHash?: number;
  operationId?: number; instanceId?: number; generation?: number; active?: number; count?: number; total?: number;
  chars?: number; bytes?: number; elapsedMs?: number; durationMs?: number; http?: number; code?: number;
  messages?: number; tools?: number; nodes?: number; keys?: number; width?: number; height?: number; widthVp?: number;
  request?: number; chunk?: number; eventCode?: number; newChats?: number; skippedChats?: number; level?: number; style?: number;
  tokens?: number; budget?: number; removed?: number; retained?: number; duplicates?: number; characters?: number;
  added?: number; updated?: number;
  round?: number; revision?: number; threads?: number; changedThreads?: number; selected?: number;
  enabled?: boolean; failed?: boolean; cancelled?: boolean; speaking?: boolean; preflight?: boolean; closed?: boolean;
  streaming?: boolean; ready?: boolean; hasModel?: boolean; retryable?: boolean;
  protocol?: string; phase?: string; action?: string; policy?: string; scheme?: string; library?: string; status?: string;
  threadId?: string; messageId?: string; sessionId?: string; providerId?: string; previewId?: string; surfaceId?: string;
}
export interface LogData { level: LogLevel; module: string; event: string; fields: Record<string, LogValue>; }
export interface LogError extends Error { code?: number | string; }
const ERROR_CODES: string[] = ['STALE_BROWSER_SNAPSHOT', 'STALE_INTERACTIVE_STATE', 'INVALID_ARGUMENTS', 'PERMISSION_DENIED',
  'CANCELLED', 'READ_ONLY', 'FILE_NOT_FOUND', 'TOOL_NOT_FOUND', 'TIMEOUT', 'CONTEXT_OVERFLOW',
  'NATIVE_EXCEPTION', 'NATIVE_EMPTY_RESULT', 'NATIVE_NAPI_FAILED'];

// Names and string values are catalogs, not free text. Unknown keys never reach either output.
const EVENTS: Record<string, string[]> = {};
EVENTS.app = ['bar_failed', 'created', 'destroyed', 'window_created', 'window_failed', 'window_loaded', 'window_destroyed', 'foreground', 'background'];
EVENTS.announcements = ['disabled', 'fetch_started', 'fetch_completed', 'fetch_failed', 'presented', 'present_failed', 'acknowledged', 'save_failed'];
EVENTS.appearance = ['material', 'material_unavailable', 'loaded', 'applied', 'save_failed', 'fonts_loaded', 'fonts_failed', 'insets_failed'];
EVENTS.backup = ['started', 'restored', 'restore_prepared', 'cleanup_failed'];
EVENTS.speech = ['preparing', 'listening', 'vad', 'complete', 'finishing', 'recognition_failed', 'cancel_failed', 'playback_requested', 'playback_failed', 'cleanup_failed', 'late_cleanup_failed'];
EVENTS.voice = ['focus_requested', 'released', 'draft_failed'];
EVENTS.web = ['engine_start', 'engine_ready', 'release', 'activate', 'failed', 'load_start', 'load_returned', 'host_ready', 'port_connected', 'ready', 'state_saved', 'attached', 'page_end', 'navigation_blocked', 'resource_failed'];
EVENTS.preview = ['failed', 'captured', 'thumbnail_failed'];
EVENTS.sandbox = ['execution_failed', 'orchestration_failed'];
EVENTS.export = ['image_failed'];
EVENTS.network = ['request_start', 'request_end', 'context_overflow', 'first_data', 'request_failed'];
EVENTS.context = ['inspected', 'request_prefix'];
EVENTS.browser = ['permission', 'control_user', 'control_agent', 'task_released', 'closed', 'failed', 'acquired', 'permission_wait', 'operation', 'observation_changed', 'opened_by_user', 'annotation_started', 'annotation_captured', 'annotation_failed'];
EVENTS.session = ['mcp_failed', 'tasks_failed', 'run_failed', 'title_failed', 'interactive_failed', 'resource_failed', 'memory_failed', 'memory_review_failed', 'mutation_failed', 'save_failed', 'observer_failed'];
EVENTS.memory = ['committed', 'review_started', 'review_discarded'];
EVENTS.resources = ['credential_rollback_failed', 'team_selected', 'committed', 'preferences_saved'];
EVENTS.diagnostics = ['started', 'stopped', 'marker', 'failed', 'level_changed'];
const NUMBERS: string[] = ['operationId', 'instanceId', 'generation', 'active', 'count', 'total', 'chars', 'bytes', 'elapsedMs', 'durationMs', 'http', 'code',
  'commonMessages', 'sharedCharacters', 'systemHash', 'toolsHash',
  'messages', 'tools', 'nodes', 'keys', 'width', 'height', 'widthVp', 'request', 'chunk', 'eventCode', 'newChats', 'skippedChats', 'level', 'style',
  'tokens', 'budget', 'removed', 'retained', 'duplicates', 'characters', 'added', 'updated', 'round', 'revision', 'threads', 'changedThreads', 'selected'];
const BOOLEANS: string[] = ['enabled', 'failed', 'cancelled', 'speaking', 'preflight', 'closed', 'streaming', 'ready', 'hasModel', 'retryable'];
const REFERENCES: string[] = ['threadId', 'messageId', 'sessionId', 'providerId', 'previewId', 'surfaceId'];
const STRINGS: Record<string, string[]> = {};
STRINGS.change = ['cold', 'append', 'tools', 'system', 'history'];
STRINGS.protocol = ['chat-completions', 'responses', 'anthropic-messages', 'gemini'];
STRINGS.phase = ['idle', 'preparing', 'listening', 'complete', 'finishing', 'error', 'creating', 'playing', 'stopping', 'connecting', 'streaming', 'capture', 'compose', 'encode'];
STRINGS.action = ['send', 'cancel', 'edit', 'press', 'none'];
STRINGS.policy = ['unset', 'enabled', 'disabled'];
STRINGS.scheme = ['http', 'https', 'about', 'data', 'file', 'other'];
STRINGS.library = ['three', 'echarts', 'none'];
STRINGS.status = ['running', 'complete', 'failed', 'cancelled', 'pending', 'running_or_unknown'];

export function knownLogEvent(module: string, event: string): boolean { return Object.keys(EVENTS).includes(module) && EVENTS[module].includes(event); }
export function logRank(level: LogLevel): number { return LOG_LEVELS.indexOf(level); }

export class LogSanitizer {
  private references: Map<string, number> = new Map<string, number>();
  reset(): void { this.references.clear(); }
  sanitize(fields: LogFields | undefined, error: Error | string | undefined, capture: boolean): Record<string, LogValue> {
    const result: Record<string, LogValue> = {};
    const raw = (fields || {}) as Record<string, LogValue>;
    Object.keys(raw).slice(0, 48).forEach((key: string) => {
      if (!NUMBERS.includes(key) && !BOOLEANS.includes(key) && !REFERENCES.includes(key) && !Object.keys(STRINGS).includes(key)) { return; }
      const value = raw[key];
      if (NUMBERS.includes(key) && typeof value === 'number' && Number.isFinite(value)) { result[key] = value; }
      else if (BOOLEANS.includes(key) && typeof value === 'boolean') { result[key] = value; }
      else if (Object.keys(STRINGS).includes(key) && typeof value === 'string') { result[key] = STRINGS[key].includes(value) ? value : '[redacted]'; }
      else if (REFERENCES.includes(key) && typeof value === 'string') {
        // Ordinals preserve correlation only within one capture. Never export the original identifier.
        if (capture && value.length <= 160) {
          let reference = this.references.get(value);
          if (reference === undefined && this.references.size < 512) { reference = this.references.size + 1; this.references.set(value, reference); }
          result[key] = reference === undefined ? '[redacted]' : 'ref-' + reference;
        } else { result[key] = '[redacted]'; }
      }
    });
    if (error !== undefined) {
      const detail = typeof error === 'string' ? error : error.message;
      const code = typeof error === 'string' ? undefined : (error as LogError).code;
      if (typeof code === 'number' && Number.isFinite(code)) { result.errorCode = code; }
      else if (typeof code === 'string' && ERROR_CODES.includes(code)) { result.errorCode = code; }
      // Arbitrary exception text may contain credentials, bodies or paths. Classify but never retain it.
      const text = (typeof detail === 'string' ? detail.slice(0, 2048) : '').toLowerCase();
      result.errorKind = /cancel|abort|取消|停止/.test(text) ? 'cancelled' : /timeout|timed out|超时/.test(text) ? 'timeout' :
        /permission|denied|权限/.test(text) ? 'permission' : /disk|storage|enospc|存储|磁盘|保存/.test(text) ? 'storage' :
        /json|parse|syntax|解析/.test(text) ? 'parse' : /network|connect|socket|网络|连接/.test(text) ? 'network' : 'unknown';
    }
    return result;
  }
}
