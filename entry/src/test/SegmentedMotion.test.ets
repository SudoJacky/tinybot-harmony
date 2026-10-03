import { describe, expect, it } from '@ohos/hypium';
import { SegmentFrame, SegmentedMotion as Rubber } from '../main/ets/common/SegmentedMotion';

export default function segmentedMotionTests(): void {
  describe('SegmentedMotion', () => {
    it('stretchesInBothDirectionsAndSettlesExactly', 0, () => {
      const first: SegmentFrame = { left: 0, right: 100 };
      const last: SegmentFrame = { left: 200, right: 300 };
      const forward = Rubber.sample(first, last, 0.3);
      const reverse = Rubber.sample(last, first, 0.3);
      expect(forward.right - forward.left > 200).assertTrue();
      expect(Math.abs(forward.left + reverse.right - 300) < 0.001).assertTrue();
      const end = Rubber.sample(first, last, 1);
      expect(end.left).assertEqual(200);
      expect(end.right).assertEqual(300);
      expect(Rubber.sample(first, last, 0.9).left > 200).assertTrue();
    });
    it('rapidReversalContinuesFromCurrentEdgesWithoutLeavingTrack', 0, () => {
      const first: SegmentFrame = { left: 0, right: 100 };
      const last: SegmentFrame = { left: 204, right: 304 };
      for (let tick = 1; tick < 20; tick++) {
        const interrupted = Rubber.sample(first, last, tick / 20);
        const start = Rubber.sample(interrupted, first, 0);
        expect(start.left).assertEqual(interrupted.left);
        expect(start.right).assertEqual(interrupted.right);
        for (let frame = 0; frame <= 20; frame++) {
          const current = Rubber.sample(interrupted, first, frame / 20);
          expect(current.left >= 0 && current.right <= 304 && current.right > current.left).assertTrue();
        }
      }
    });
    it('doesNotDeformUnchangedSelectionOrEmptyGeometry', 0, () => {
      const same: SegmentFrame = { left: 80, right: 160 };
      const empty: SegmentFrame = { left: 0, right: 0 };
      for (let frame = 0; frame <= 20; frame++) {
        expect(Rubber.sample(same, same, frame / 20).left).assertEqual(80);
        expect(Rubber.sample(same, same, frame / 20).right).assertEqual(160);
        expect(Rubber.sample(empty, empty, frame / 20).right).assertEqual(0);
      }
    });
  });
}
