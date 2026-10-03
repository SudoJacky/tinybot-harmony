// Gesture distances are in vp; velocity is in vp/s.
export class SwipeRowMotion {
  static readonly drawer: number = 80;
  static reveal(distance: number, width: number): number {
    const limit = Math.max(0, width);
    const value = Math.max(0, distance);
    return Math.min(limit, value <= SwipeRowMotion.drawer ? value :
      SwipeRowMotion.drawer + (value - SwipeRowMotion.drawer) * 0.55);
  }
  static threshold(width: number): number { return Math.max(120, width * 0.6); }
  static armed(reveal: number, width: number): boolean {
    return width >= 160 && reveal >= SwipeRowMotion.threshold(width);
  }
  static staysOpen(reveal: number, velocityX: number): boolean {
    if (velocityX > 450) return false;
    if (velocityX < -450) return true;
    return reveal >= SwipeRowMotion.drawer / 2;
  }
}
