export type LogLevel = 'debug' | 'info' | 'warn' | 'error';
export const LOG_LEVELS: LogLevel[] = ['debug', 'info', 'warn', 'error'];
export type LogValue = string | number | boolean;
export interface LogFields {
  operation?: string; credentialScope?: string; rpcMethod?: string;
  sdk?: number; initialSupported?: boolean; supported?: boolean; available?: boolean; reason?: string; format?: string;
  scriptSource?: string; line?: number; pageSceneObserver?: boolean;
  mounted?: boolean; attached?: boolean; visible?: boolean; foreground?: boolean;
  setting?: string; dataVersion?: number; serverId?: string; deviceId?: string;
  change?: string; commonMessages?: number; sharedCharacters?: number; systemHash?: number; toolsHash?: number;
  operationId?: number; instanceId?: number; generation?: number; active?: number; count?: number; total?: number;
  chars?: number; bytes?: number; elapsedMs?: number; durationMs?: number; delayMs?: number; firstTokenMs?: number; outputTokens?: number; http?: number; code?: number;
  messages?: number; tools?: number; nodes?: number; keys?: number; width?: number; height?: number; widthVp?: number;
  request?: number; chunk?: number; eventCode?: number; newChats?: number; skippedChats?: number; level?: number; style?: number;
  tokens?: number; budget?: number; removed?: number; retained?: number; duplicates?: number; characters?: number;
  added?: number; updated?: number;
  round?: number; revision?: number; threads?: number; changedThreads?: number; selected?: number;
  requests?: number; panels?: number; boards?: number;
  enabled?: boolean; failed?: boolean; cancelled?: boolean; uncertain?: boolean; speaking?: boolean; preflight?: boolean; closed?: boolean;
  streaming?: boolean; ready?: boolean; hasModel?: boolean; retryable?: boolean;
  protocol?: string; phase?: string; action?: string; policy?: string; scheme?: string; library?: string; status?: string; balanceAdapter?: string;
  threadId?: string; messageId?: string; sessionId?: string; providerId?: string; previewId?: string; surfaceId?: string;
  channel?: string;
}
export interface LogData { level: LogLevel; module: string; event: string; fields: Record<string, LogValue>; }
interface LogFailureDetails { httpStatus?: number; nativeCode?: number; remoteCode?: number; service?: string; }
export interface LogError extends Error {
  code?: number | string; details?: LogFailureDetails;
  httpStatus?: number; nativeCode?: number; providerCode?: string; stage?: string;
}
const ERROR_CODES: string[] = ['STALE_BROWSER_SNAPSHOT', 'STALE_INTERACTIVE_STATE', 'INVALID_ARGUMENTS', 'PERMISSION_DENIED',
  'CANCELLED', 'READ_ONLY', 'FILE_NOT_FOUND', 'TOOL_NOT_FOUND', 'TIMEOUT', 'CONTEXT_OVERFLOW', 'SHARED_FOLDER_AUTH_REQUIRED',
  'NATIVE_EXCEPTION', 'NATIVE_EMPTY_RESULT', 'NATIVE_NAPI_FAILED', 'FS_STALE_VERSION', 'FS_NOT_OBSERVED', 'FS_EXTERNAL_IO',
  'ALREADY_EXISTS', 'AUTH_REQUIRED', 'BROWSER_BUSY', 'BROWSER_CLOSED', 'BROWSER_HISTORY_EMPTY', 'BROWSER_LOAD_FAILED',
  'BROWSER_NOT_OWNED', 'BROWSER_NOT_VISIBLE', 'BROWSER_OBSERVATION_FAILED', 'BROWSER_OBSERVATION_INTERRUPTED', 'BROWSER_UNAVAILABLE',
  'CONTENT_UNAVAILABLE', 'EVIDENCE_REQUIRED', 'EXECUTION_FAILED', 'FS_AMBIGUOUS_MATCH', 'FS_INCOMPLETE_LIST',
  'FS_INVALID_ARGUMENTS', 'FS_INVALID_CURSOR', 'FS_INVALID_EDITS', 'FS_INVALID_PATH', 'FS_MATCH_NOT_FOUND',
  'FS_OVERLAPPING_EDITS', 'FS_STALE_SEARCH', 'HANDOFF_REQUIRED', 'HTTP_ERROR', 'INTERNAL_ERROR', 'INVALID_RESPONSE',
  'INVALID_RESULT', 'INVALID_STATE', 'LIMIT_EXCEEDED', 'NETWORK_ERROR', 'NOT_CONFIGURED', 'NOT_EXECUTED', 'NOT_FOUND',
  'OUTCOME_UNKNOWN', 'PREVIEW_INVALID', 'PREVIEW_NOT_FOUND', 'PREVIEW_NOT_READY', 'QUOTA_EXHAUSTED', 'RATE_LIMITED',
  'REMOTE_ERROR', 'REMOTE_TOOL_ERROR', 'RESPONSE_BUDGET_EXCEEDED', 'SCHEMA_REQUIRED', 'SEARCH_LAYOUT_CHANGED',
  'SEARCH_PAGE_CHANGED', 'SEARCH_VERIFICATION_REQUIRED', 'STALE_BROWSER_ELEMENT', 'STALE_RESOURCE', 'TOOL_UNAVAILABLE',
  'UNKNOWN_ERROR', 'OUTPUT_INVALID', 'MODEL_FAILED', 'DATA_INVALID', 'DATA_UNAVAILABLE', 'UNSUPPORTED_CONTENT', 'UNSUPPORTED_PREVIEW_FORMAT', 'UNSUPPORTED_PROTOCOL', 'USER_DENIED'];

// Names and string values are catalogs, not free text. Unknown keys never reach either output.
const EVENTS: Record<string, string[]> = {};
EVENTS.app = ['bar_failed', 'created', 'destroyed', 'window_created', 'window_failed', 'window_loaded', 'window_destroyed', 'foreground', 'background'];
EVENTS.announcements = ['disabled', 'fetch_started', 'fetch_completed', 'fetch_failed', 'presented', 'present_failed', 'acknowledged', 'save_failed'];
EVENTS.review = ['task_completed', 'presented', 'present_failed', 'accepted', 'deferred', 'disabled', 'request_completed', 'request_failed', 'save_failed'];
EVENTS.appearance = ['material', 'material_support', 'material_unavailable', 'loaded', 'applied', 'save_failed', 'fonts_loaded', 'fonts_failed', 'insets_failed', 'keyboard_geometry'];
EVENTS.language = ['load_failed', 'save_failed'];
EVENTS.camera = ['dismissed', 'imported', 'capture_failed'];
EVENTS.account = ['restore_failed', 'response_invalid', 'state_changed', 'sign_in_cancelled', 'sign_in_failed', 'sign_out_failed', 'state_failed'];
EVENTS.privacy = ['request_started', 'query_completed', 'query_retry', 'using_cached_consent', 'check_failed',
  'subscription_ready', 'subscription_cleanup_failed'];
EVENTS.feedback = ['attachment_failed', 'log_failed', 'initialize_failed', 'save_failed', 'credential_failed', 'request_failed', 'submit_failed', 'list_failed',
  'detail_failed', 'upload_failed', 'cleanup_failed', 'reconcile_failed', 'delete_failed'];
EVENTS.backup = ['started', 'restored', 'restore_prepared', 'key_decrypt_failed', 'cleanup_failed', 'replace_failed', 'retire_failed', 'rollback_failed', 'archive_written', 'archive_write_failed', 'archive_verified',
  'restore_completed', 'restore_failed', 'startup_capture_failed', 'startup_marker_failed', 'startup_lookup_failed',
  'cloud_retry_finished', 'cloud_failed', 'cloud_retry', 'cloud_sync_progress', 'cloud_sync_finished', 'cloud_list_failed', 'cloud_settings_failed', 'auto_failed', 'auto_settings_failed', 'auto_task_failed', 'auto_expired', 'auto_release_failed',
  'webdav_failed', 'webdav_cleanup_failed', 'webdav_uploaded', 'webdav_settings_failed'];
EVENTS['life-panel'] = ['published', 'refresh_skipped', 'refresh_started', 'refresh_complete', 'refresh_cancelled', 'refresh_failed', 'manifest_failed', 'action_failed', 'expiry_failed', 'connection_failed', 'api_response', 'api_failed', 'transform_started', 'transform_complete', 'transform_failed'];
EVENTS.background = ['acquired', 'released', 'cancelled', 'suspended', 'release_failed', 'stop_failed', 'transition_failed', 'window_expired'];
EVENTS.notification = ['authorization_checked', 'authorization_denied', 'authorization_failed', 'disabled', 'published', 'publish_failed'];
EVENTS.speech = ['preparing', 'listening', 'vad', 'complete', 'finishing', 'recognition_failed', 'cancel_failed', 'playback_requested', 'playback_failed', 'cleanup_failed', 'late_cleanup_failed'];
EVENTS.voice = ['focus_requested', 'released', 'draft_failed'];
EVENTS.composer = ['sheet_action_queued', 'sheet_action_dispatched', 'sheet_action_cancelled', 'send_focus_failed'];
EVENTS.focus = ['search_requested', 'provider_requested', 'onboarding_requested'];
EVENTS.navigation = ['tools_opened', 'tools_repeated', 'settings_opened', 'settings_repeated',
  'new_chat_blocked', 'new_chat_failed', 'new_chat_revealed'];
EVENTS.web = ['storage_failed', 'engine_start', 'engine_ready', 'release', 'activate', 'failed', 'console_error', 'load_start', 'load_returned', 'host_ready', 'port_connected', 'ready', 'state_saved', 'attached', 'page_end', 'navigation_blocked', 'resource_failed'];
EVENTS.office_preview = ['load_failed', 'update_annotations_failed', 'render_failed', 'annotation_failed', 'page_failed'];
EVENTS.math = ['load_failed', 'render_failed', 'startup_timeout', 'process_exited', 'page_failed'];
EVENTS.mermaid = ['startup_timeout', 'render_timeout', 'script_failed', 'diagram_failed', 'page_failed', 'process_exited'];
EVENTS.preview = ['failed', 'captured', 'thumbnail_failed', 'surface_moved'];
EVENTS.sandbox = ['execution_failed', 'orchestration_failed'];
EVENTS.tool = ['failed', 'partial'];
EVENTS.workspace = ['mutation_failed', 'preview_failed', 'folder_support_failed', 'folder_picker_support_failed', 'folder_persist_failed', 'folder_activate_failed', 'folder_revoke_failed', 'folder_startup_failed'];
EVENTS.storage = ['scan_failed', 'metric_failed', 'cleanup_failed', 'cleanup_protected', 'usage_save_failed', 'migration_committed'];
EVENTS.mcp = ['request_failed', 'cancel_notice_failed', 'browser_launch_failed'];
EVENTS.mail = ['transport_failed', 'cleanup_failed', 'account_saved', 'account_removed', 'query_started', 'query_complete', 'query_failed', 'command_failed', 'settings_failed'];
EVENTS.export = ['image_failed', 'preview_failed', 'cleanup_failed', 'share_failed', 'save_failed'];
EVENTS.network = ['request_start', 'request_end', 'context_overflow', 'first_data', 'request_failed'];
EVENTS.sync = ['nearby_attachments_received', 'nearby_conflict_resolved', 'nearby_failed', 'nearby_device_failed', 'workspace_delete_conflict', 'workspace_delete_unversioned', 'conversation_accept_failed', 'conversation_connect_failed', 'conversation_disconnect_failed',
  'conversation_destroy_failed', 'conversation_receive_failed', 'conversation_progress_failed', 'conversation_admission_failed',
  'conversation_admitted', 'conversation_acknowledged', 'conversation_executor_open_failed', 'conversation_frame_invalid', 'conversation_live_started',
  'conversation_route_ready', 'conversation_connected', 'conversation_authorized', 'conversation_input_saved',
  'conversation_run_started', 'conversation_first_output', 'conversation_first_output_sent', 'conversation_snapshot_sent', 'conversation_snapshot_applied',
  'conversation_output_applied', 'conversation_opened', 'nearby_push', 'nearby_pull', 'nearby_flush',
  'probe_failed', 'probe_declined', 'probe_connected', 'probe_acknowledged', 'probe_received'];
EVENTS.moderation = ['guard_stopped', 'output_words_stopped'];
EVENTS.context = ['inspected', 'request_prefix'];
EVENTS.browser = ['permission', 'control_user', 'control_agent', 'control_wait', 'task_released', 'closed', 'failed', 'acquired', 'permission_wait', 'operation', 'observation_changed', 'opened_by_user', 'annotation_started', 'annotation_captured', 'annotation_failed', 'search_observed', 'search_failed', 'capture_started', 'frame_captured', 'capture_finished'];
EVENTS.session = ['run_started', 'run_finished', 'run_cancelled', 'mcp_failed', 'tasks_failed', 'run_failed', 'title_failed', 'interactive_failed', 'resource_failed', 'memory_failed', 'memory_review_failed', 'mutation_failed', 'save_failed', 'observer_failed'];
EVENTS.memory = ['committed', 'review_started', 'review_discarded'];
EVENTS.resources = ['credential_rollback_failed', 'credential_cleanup_failed', 'team_selected', 'committed', 'preferences_saved'];
EVENTS.configuration = ['unsupported', 'load_failed', 'save_failed'];
EVENTS.provider = ['discovery_failed', 'balance_failed', 'balance_completed'];
EVENTS.diagnostics = ['started', 'stopped', 'marker', 'failed', 'level_changed'];
const NUMBERS: string[] = ['sdk', 'line', 'operationId', 'instanceId', 'generation', 'active', 'count', 'total', 'chars', 'bytes', 'elapsedMs', 'durationMs', 'delayMs', 'firstTokenMs', 'outputTokens', 'http', 'code',
  'commonMessages', 'sharedCharacters', 'systemHash', 'toolsHash', 'dataVersion',
  'messages', 'tools', 'nodes', 'keys', 'width', 'height', 'widthVp', 'request', 'chunk', 'eventCode', 'newChats', 'skippedChats', 'level', 'style',
  'tokens', 'budget', 'removed', 'retained', 'duplicates', 'characters', 'added', 'updated', 'round', 'revision', 'threads', 'changedThreads', 'selected', 'requests', 'panels', 'boards'];
const BOOLEANS: string[] = ['initialSupported', 'supported', 'available', 'pageSceneObserver', 'mounted', 'attached', 'visible', 'foreground', 'enabled', 'failed', 'cancelled', 'uncertain', 'speaking', 'preflight', 'closed', 'streaming', 'ready', 'hasModel', 'retryable'];
const REFERENCES: string[] = ['threadId', 'messageId', 'sessionId', 'providerId', 'previewId', 'surfaceId', 'serverId', 'deviceId'];
const STRINGS: Record<string, string[]> = {};
STRINGS.channel = ['answer', 'reasoning'];
STRINGS.balanceAdapter = ['deepseek', 'sub2api', 'newapi', 'newapi-account', 'zhipu', 'custom'];
STRINGS.operation = ['access', 'read', 'list', 'stat', 'parse', 'unlink', 'rmdir', 'bundle_stats', 'free_size', 'total_size',
  'getAppPrivacyMgmtInfo', 'getAppPrivacyResult', 'requestAppPrivacyConsent', 'subscribe', 'unsubscribe', 'cloud_directory', 'cloud_sync',
  'connect', 'login', 'examine', 'search', 'fetch', 'identify', 'capability',
  'discover', 'balance', 'credential_read', 'credential_write', 'credential_remove', 'save_config', 'response', 'streaming', 'connecting', 'attachment', 'log',
  'PUT', 'MOVE', 'DELETE', 'GET', 'PROPFIND', 'MKCOL', 'local', 'remote'];
STRINGS.credentialScope = ['provider', 'search', 'mcp', 'backup'];
STRINGS.rpcMethod = ['initialize', 'tools/list', 'tools/call', 'notifications/initialized', 'notifications/cancelled'];
STRINGS.service = ['mcp', 'search', 'web', 'bing-browser'];
STRINGS.reason = ['api_level', 'device_unsupported', 'construction_failed', 'capability_changed', 'supported',
  'user_control', 'idle_browser', 'user_handoff', 'task_acquired'];
STRINGS.format = ['image', 'markdown', 'docx', 'xlsx', 'pptx'];
STRINGS.scriptSource = ['generated', 'host', 'frame', 'blank', 'data', 'other', 'unknown'];
STRINGS.setting = ['search.provider', 'providerProfiles.protocol', 'extensions.browserPolicy', 'config.reasoning',
  'capabilities.reasoning', 'threads.agentMode', 'threads.disabledTools', 'threads.reasoningEffort', 'servers.authType',
  'feedback.seenReplies', 'feedback.pendingSubmission', 'feedback.uploadQueue'];
STRINGS.change = ['cold', 'append', 'tools', 'system', 'history'];
STRINGS.protocol = ['chat-completions', 'responses', 'anthropic-messages', 'gemini'];
STRINGS.phase = ['idle', 'preparing', 'listening', 'complete', 'finishing', 'error', 'creating', 'playing', 'stopping', 'connecting', 'streaming', 'capture', 'compose', 'encode',
  'login', 'state', 'storage', 'credential', 'identity', 'submit', 'query', 'upload',
  'page_show', 'privacy_event', 'subscription_ready', 'new_want', 'business', 'manual_retry', 'request_consent', 'initial', 'active'];
STRINGS.action = ['local', 'remote', 'send', 'cancel', 'edit', 'press', 'none', 'open', 'click', 'type', 'select', 'scroll', 'back', 'forward', 'reload', 'capture', 'wait'];
STRINGS.policy = ['unset', 'enabled', 'disabled'];
STRINGS.scheme = ['http', 'https', 'about', 'data', 'file', 'other'];
STRINGS.library = ['three', 'echarts', 'charts', 'none'];
STRINGS.status = ['running', 'complete', 'failed', 'cancelled', 'pending', 'running_or_unknown', 'results', 'empty', 'verification', 'unexpected_page', 'invalid_results'];

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
      if (typeof error !== 'string') {
        const evidence = error as LogError;
        if (typeof evidence.nativeCode === 'number' && Number.isFinite(evidence.nativeCode)) { result.nativeCode = evidence.nativeCode; }
        if (typeof evidence.httpStatus === 'number' && Number.isFinite(evidence.httpStatus)) { result.http = evidence.httpStatus; }
        if (typeof evidence.providerCode === 'string' && /^[a-zA-Z0-9_.-]{1,80}$/.test(evidence.providerCode) && !/^sk-/i.test(evidence.providerCode)) {
          result.providerCode = evidence.providerCode;
        }
        if (evidence.stage && STRINGS.operation.includes(evidence.stage)) {
          result.operation = evidence.stage;
          if (typeof evidence.code === 'string' && /^[a-zA-Z0-9_.-]{1,80}$/.test(evidence.code) && !/^sk-/i.test(evidence.code)) {
            result.errorCode = evidence.code;
          }
        }
      }
      const detail = typeof error === 'string' ? error : error.message;
      const code = typeof error === 'string' ? undefined : (error as LogError).code;
      if (typeof code === 'number' && Number.isFinite(code)) { result.errorCode = code; }
      else if (typeof code === 'string' && ERROR_CODES.includes(code)) {
        result.errorCode = code;
        // Tool failures contain payloads and paths too. Copy only numeric protocol evidence
        // and known service names; never enumerate or serialize the details object.
        const details = (error as LogError).details;
        if (details && typeof details === 'object') {
          if (typeof details.httpStatus === 'number' && Number.isFinite(details.httpStatus)) { result.http = details.httpStatus; }
          if (typeof details.nativeCode === 'number' && Number.isFinite(details.nativeCode)) { result.nativeCode = details.nativeCode; }
          if (typeof details.remoteCode === 'number' && Number.isFinite(details.remoteCode)) { result.remoteCode = details.remoteCode; }
          if (typeof details.service === 'string' && STRINGS.service.includes(details.service)) { result.service = details.service; }
        }
      }
      // Arbitrary exception text may contain credentials, bodies or paths. Classify but never retain it.
      const text = (typeof detail === 'string' ? detail.slice(0, 2048) : '').toLowerCase();
      result.errorKind = /cancel|abort|取消|停止/.test(text) ? 'cancelled' : /timeout|timed out|超时/.test(text) ? 'timeout' :
        /permission|denied|权限/.test(text) ? 'permission' : /disk|storage|enospc|存储|磁盘|保存/.test(text) ? 'storage' :
        /json|parse|syntax|解析/.test(text) ? 'parse' : /network|connect|socket|网络|连接/.test(text) ? 'network' : 'unknown';
    }
    return result;
  }
}
