export type VoiceAction = 'send' | 'cancel' | 'edit';
export interface VoiceTargetRect { x: number; y: number; width: number; height: number; }

function contains(rect: VoiceTargetRect | undefined, x: number, y: number): boolean {
  return rect !== undefined && x >= rect.x && x <= rect.x + rect.width &&
    y >= rect.y && y <= rect.y + rect.height;
}

export function voiceActionAtPoint(x: number, y: number, cancel?: VoiceTargetRect, edit?: VoiceTargetRect): VoiceAction {
  if (contains(cancel, x, y)) { return 'cancel'; }
  if (contains(edit, x, y)) { return 'edit'; }
  return 'send';
}
