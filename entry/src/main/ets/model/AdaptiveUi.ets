// Logical window units, shared by phone, split-screen and tablet surfaces.
export class AdaptiveUi {
  static readonly formWidth: number = 640;
  static readonly readingWidth: number = 680;
  static readonly choiceWidth: number = 480;
  static compactComposer(width: number): boolean { return width > 0 && width < 520; }
}
