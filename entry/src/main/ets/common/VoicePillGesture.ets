export type VoicePillAction = 'none' | 'start' | 'finish' | 'cancel';

// One captured finger; a short tap toggles, a hold records until release.
export class VoicePillGesture {
  pointer: number = -1;
  pressed: boolean = false;
  pull: number = 0;
  private origin: number = 0;
  private held: boolean = false;
  private consumed: boolean = false;
  private wasActive: boolean = false;

  down(id: number, x: number, active: boolean): boolean {
    if (this.pointer !== -1) { return false; }
    this.pointer = id; this.origin = x; this.wasActive = active;
    this.pressed = true; this.pull = 0; this.held = false; this.consumed = false;
    return true;
  }

  hold(): VoicePillAction {
    if (this.pointer === -1 || this.held || this.consumed || this.pull > 4) { return 'none'; }
    this.held = true;
    return this.wasActive ? 'none' : 'start';
  }

  move(id: number, x: number, active: boolean): VoicePillAction {
    if (id !== this.pointer || this.consumed) { return 'none'; }
    this.pull = Math.max(0, Math.min(88, this.origin - x));
    if (this.pull >= 64) {
      this.consumed = true; this.pressed = false;
      return active || this.held ? 'cancel' : 'none';
    }
    return 'none';
  }

  up(id: number): VoicePillAction {
    if (id !== this.pointer) { return 'none'; }
    const action: VoicePillAction = this.consumed || (!this.held && !this.wasActive && this.pull > 4) ? 'none' :
      this.wasActive || this.held ? 'finish' : 'start';
    this.reset();
    return action;
  }

  interrupt(): VoicePillAction {
    const action: VoicePillAction = !this.consumed && (this.held || this.wasActive) ? 'cancel' : 'none';
    this.reset(); return action;
  }

  reset(): void {
    this.pointer = -1; this.pressed = false; this.pull = 0;
    this.held = false; this.consumed = false; this.wasActive = false;
  }
}
