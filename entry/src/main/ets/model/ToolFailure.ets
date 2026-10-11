// Stable diagnostics are separate from localized text and never authorize a retry.
export class ToolFailure extends Error {
  code: string;
  recovery: string;
  path?: string;
  editIndex?: number;
  constructor(code: string, message: string, recovery: string, path?: string, editIndex?: number) {
    super(message); this.code = code; this.recovery = recovery; this.path = path; this.editIndex = editIndex;
  }
}
