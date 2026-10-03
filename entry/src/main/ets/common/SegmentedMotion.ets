export interface SegmentFrame {
  left: number;
  right: number;
}

// Independent native motion: the leading edge arrives first, the trailing edge
// catches up, then compresses slightly into the destination before relaxing.
export class SegmentedMotion {
  static readonly duration: number = 420;

  private static unit(value: number): number { return Math.max(0, Math.min(1, value)); }

  static sample(from: SegmentFrame, target: SegmentFrame, progress: number): SegmentFrame {
    const t = SegmentedMotion.unit(progress);
    if (t === 0) return { left: from.left, right: from.right };
    if (t === 1) return { left: target.left, right: target.right };
    const forward = target.left + target.right >= from.left + from.right;
    const lead = 1 - Math.pow(1 - SegmentedMotion.unit(t / 0.44), 3);
    const catchup = SegmentedMotion.unit((t - 0.17) / 0.64);
    const trail = catchup * catchup * (3 - 2 * catchup);
    let left = from.left + (target.left - from.left) * (forward ? trail : lead);
    let right = from.right + (target.right - from.right) * (forward ? lead : trail);
    const distance = Math.abs(target.left - from.left) + Math.abs(target.right - from.right);
    const compression = Math.min(2.2, (target.right - target.left) * 0.08, distance * 0.05) *
      Math.sin(Math.PI * SegmentedMotion.unit((t - 0.81) / 0.19));
    if (forward) left += compression;
    else right -= compression;
    return { left: left, right: Math.max(left, right) };
  }
}
