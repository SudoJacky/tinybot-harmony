export interface ToolFailureDetails {
  path?: string;
  editIndex?: number;
  service?: string;
  httpStatus?: number;
  remoteCode?: number;
  nativeCode?: number;
  result?: Object;
}

// Stable diagnostics are separate from localized text and never authorize a retry.
export class ToolFailure extends Error {
  code: string;
  recovery: string;
  details?: ToolFailureDetails;
  constructor(code: string, message: string, recovery: string, details?: ToolFailureDetails) {
    super(message); this.code = code; this.recovery = recovery; this.details = details;
  }
}

export function parseToolArguments(text: string): Object {
  try { return JSON.parse(text) as Object; }
  catch (_) { throw new ToolFailure('INVALID_ARGUMENTS', 'Tool arguments must be valid JSON.', 'fix_arguments'); }
}

export function parseToolResponse(text: string): Object {
  try { return JSON.parse(text) as Object; }
  catch (_) { throw new ToolFailure('INVALID_RESPONSE', 'Service returned invalid JSON.', 'inspect_service'); }
}

// HTTP classification uses the actual status, never localized message matching.
export function toolHttpFailure(status: number, message: string, service: string): ToolFailure {
  const details: ToolFailureDetails = { service: service, httpStatus: status };
  if (status === 401) { return new ToolFailure('AUTH_REQUIRED', message, 'check_credentials', details); }
  if (status === 403) { return new ToolFailure('PERMISSION_DENIED', message, 'check_permissions', details); }
  if (status === 404) { return new ToolFailure('NOT_FOUND', message, 'check_resource', details); }
  if (status === 429) { return new ToolFailure('RATE_LIMITED', message, 'wait_then_check', details); }
  return new ToolFailure('HTTP_ERROR', message, 'inspect_service', details);
}

export class ToolResultError extends ToolFailure {
  output: string;
  constructor(output: string, code: string = 'EXECUTION_FAILED', recovery: string = 'inspect_result_before_retry') {
    super(code, 'Tool execution failed', recovery);
    // Retain domain receipts (logs, status, child calls) while adding the common fields.
    const result = JSON.parse(output) as Record<string, Object>;
    if (typeof result.error !== 'string' || !result.error) { result.error = this.message; }
    result.code = code; result.recovery = recovery;
    this.output = JSON.stringify(result);
  }
}
