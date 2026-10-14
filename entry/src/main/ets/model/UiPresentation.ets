import { UiValues } from './InteractiveUi';

export interface UiDraft { values: UiValues; dirty: boolean; invalid: string[]; }

// Small per-message presentation state survives lazy row disposal; never retain Web controllers or pixels.
export class UiPresentation {
  drafts: Map<string, UiDraft> = new Map<string, UiDraft>();
  webHeights: Map<string, number> = new Map<string, number>();
}
