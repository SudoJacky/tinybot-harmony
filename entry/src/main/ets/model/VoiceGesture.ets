export type VoiceAction = 'send' | 'cancel' | 'edit';
export interface VoiceTargetRect { x: number; y: number; width: number; height: number; }

function contains(rect: VoiceTargetRect | undefined, x: number, y: number): boolean {
  // The label and a small margin belong to the same finger-sized drop target.
  return rect !== undefined && x >= rect.x - 12 && x <= rect.x + rect.width + 12 &&
    y >= rect.y - 12 && y <= rect.y + rect.height + 12;
}

export function voiceActionAtPoint(x: number, y: number, cancel?: VoiceTargetRect, edit?: VoiceTargetRect): VoiceAction {
  if (contains(cancel, x, y)) { return 'cancel'; }
  if (contains(edit, x, y)) { return 'edit'; }
  return 'send';
}
