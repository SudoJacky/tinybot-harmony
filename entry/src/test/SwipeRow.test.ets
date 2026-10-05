import { describe, expect, it } from '@ohos/hypium';
import { SwipeRowMotion as Swipe } from '../main/ets/common/SwipeRowMotion';

export default function swipeRowTests(): void {
  describe('SwipeRow', () => {
    it('requiresDeliberateDeepDragAndResistsOverscroll', 0, () => {
      expect(Swipe.reveal(-20, 320)).assertEqual(0);
      expect(Swipe.reveal(80, 320)).assertEqual(80);
      expect(Swipe.reveal(120, 320) < 120).assertTrue();
      expect(Swipe.armed(Swipe.reveal(120, 320), 320)).assertFalse();
      // A shorter deliberate drag arms deletion; pulling back disarms it again.
      expect(Swipe.armed(Swipe.reveal(245, 320), 320)).assertTrue();
      expect(Swipe.armed(Swipe.reveal(235, 320), 320)).assertFalse();
      expect(Swipe.armed(Swipe.reveal(300, 320), 320)).assertTrue();
      expect(Swipe.reveal(10000, 320)).assertEqual(320);
      expect(Swipe.armed(130, 130)).assertFalse();
    });
    it('snapsByDistanceOrDirectionWithoutTreatingAFlickAsDeletion', 0, () => {
      expect(Swipe.staysOpen(39, 0)).assertFalse();
      expect(Swipe.staysOpen(41, 0)).assertTrue();
      expect(Swipe.staysOpen(20, -600)).assertTrue();
      expect(Swipe.staysOpen(70, 600)).assertFalse();
      expect(Swipe.armed(20, 320)).assertFalse();
    });
  });
}
