// Model-facing conclusions augment receipts; original fields and committed effects stay intact.
export interface ToolConclusion {
  status: string;
  message: string;
  recovery: string;
  notices: string[];
}
export class ToolOutcome {
  output: string;
  failed: boolean;
  partial: boolean;
  constructor(output: string, failed: boolean, partial: boolean = false) { this.output = output; this.failed = failed; this.partial = partial; }
}
function stringField(result: Record<string, Object>, key: string): string {
  return typeof result[key] === 'string' ? result[key] as string : '';
}
function reductions(result: Record<string, Object>, prefix: string): string[] {
  const notices: string[] = [];
  if (result.truncated === true) {
    notices.push(prefix + 'Content is incomplete. Use nextOffset/nextColumn/nextCursor when supplied; otherwise request a narrower scope or another browser observation.');
  }
  if (result.hasMore === true) { notices.push(prefix + 'More results are available; continue with the returned cursor.'); }
  if (result.previewOnly === true) { notices.push(prefix + 'Only a historical excerpt was retained. The missing original text cannot be recovered from this snapshot.'); }
  if (result.linksTruncated === true) { notices.push(prefix + 'The link list was shortened; it is not a complete inventory of page links.'); }
  if (result.logsTruncated === true) { notices.push(prefix + 'stdout/stderr were shortened to the shared 32 KiB log budget. The operation may have completed; inspect its result before retrying. Return required data instead of logging it.'); }
  if (result.resultTruncated === true) { notices.push(prefix + 'The returned value is incomplete; do not treat it as the full result.'); }
  if (Array.isArray(result.skipped) && (result.skipped as Object[]).length) {
    notices.push(prefix + 'Some resources could not be read. See skipped for their paths and reasons; search results are incomplete.');
  }
  if (Array.isArray(result.reductions)) {
    for (const notice of result.reductions as string[]) { if (typeof notice === 'string') { notices.push(prefix + notice); } }
  }
  if (Array.isArray(result.errors)) {
    if ((result.errors as Object[]).length) { notices.push(prefix + 'Runtime or observation errors were reported. Their complete diagnostics are retained in errors; inspect them before claiming successful verification.'); }
  }
  if (Array.isArray(result.issues) && (result.issues as Object[]).length) {
    notices.push(prefix + 'Some child calls failed or returned partial results. Inspect issues and saved child receipts before retrying any effects.');
  }
  return notices;
}
export function toolOutcome(output: string, failed: boolean = false): ToolOutcome {
  let value: Object;
  try { value = JSON.parse(output) as Object; }
  catch (_) {
    if (!failed) { return new ToolOutcome(output, false); }
    const conclusion: ToolConclusion = { status: 'failed', message: output, recovery: 'inspect_error_before_retry', notices: [] };
    return new ToolOutcome(JSON.stringify({ error: output, code: 'UNKNOWN_ERROR', conclusion: conclusion }), true);
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    if (!failed) { return new ToolOutcome(output, false); }
    return toolOutcome(JSON.stringify({ error: output, code: 'UNKNOWN_ERROR' }), true);
  }
  const result = value as Record<string, Object>;
  const error = stringField(result, 'error');
  failed = failed || !!error || result.isError === true;
  const notices = reductions(result, '');
  if (result.page && typeof result.page === 'object' && !Array.isArray(result.page)) {
    notices.push(...reductions(result.page as Record<string, Object>, 'Page: '));
  }
  if (!failed && !notices.length) { return new ToolOutcome(output, false); }
  const message = failed ? 'The tool reported a failure. Complete diagnostics are retained in error/details. Inspect any committed effects before retrying.' :
    'The tool returned a partial observation or reduced content. Do not assume this is the complete result.';
  const recovery = stringField(result, 'recovery') || (failed ? 'inspect_error_and_effects_before_retry' : 'inspect_notices_and_continue_reading');
  if (failed && !stringField(result, 'code')) { result.code = 'EXECUTION_FAILED'; }
  if (!stringField(result, 'recovery')) { result.recovery = recovery; }
  const conclusion: ToolConclusion = { status: result.code === 'CANCELLED' ? 'cancelled' : failed ? 'failed' : 'partial',
    message: message, recovery: recovery, notices: notices };
  result.conclusion = conclusion;
  return new ToolOutcome(JSON.stringify(result), failed, !failed && notices.length > 0);
}
