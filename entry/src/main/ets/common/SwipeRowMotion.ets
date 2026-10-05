// Gesture distances are in vp; velocity is in vp/s.
export class SwipeRowMotion {
  static readonly drawer: number = 80;
  private static readonly resistance: number = 0.55;
  static dragOrigin(reveal: number): number {
    return reveal <= SwipeRowMotion.drawer ? reveal :
      SwipeRowMotion.drawer + (reveal - SwipeRowMotion.drawer) / SwipeRowMotion.resistance;
  }
  static reveal(distance: number, width: number): number {
    const limit = Math.max(0, width);
    const value = Math.max(0, distance);
    return Math.min(limit, value <= SwipeRowMotion.drawer ? value :
      SwipeRowMotion.drawer + (value - SwipeRowMotion.drawer) * SwipeRowMotion.resistance);
  }
  static threshold(width: number): number { return Math.max(120, width * 0.52); }
  static armed(reveal: number, width: number): boolean {
    return width >= 160 && reveal >= SwipeRowMotion.threshold(width);
  }
  static staysOpen(reveal: number, velocityX: number): boolean {
    if (velocityX > 450) return false;
    if (velocityX < -450) return true;
    return reveal >= SwipeRowMotion.drawer / 2;
  }
}
