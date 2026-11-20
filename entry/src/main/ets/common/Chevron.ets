export type ChevronDirection = 'down' | 'up' | 'left' | 'right';

export const CHEVRON_SIZE: number = 16;

@Component
export struct Chevron {
  @Prop pointing: ChevronDirection = 'down';
  @Prop tint: ResourceColor = $r('app.color.text_tertiary');

  private pathCommands(): string {
    switch (this.pointing) {
      case 'down': return 'M 2 4 L 8 12 L 14 4';
      case 'up': return 'M 2 12 L 8 4 L 14 12';
      case 'left': return 'M 12 2 L 4 8 L 12 14';
      case 'right': return 'M 4 2 L 12 8 L 4 14';
    }
  }

  build() {
    Shape() {
      // Round 2vp strokes give each direction a 10vp short edge, including room for press scaling.
      Path().commands(this.pathCommands()).fill(Color.Transparent).stroke(this.tint)
        .strokeWidth('2px').strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
    }.viewPort({ x: 0, y: 0, width: '16px', height: '16px' })
      .width(CHEVRON_SIZE).height(CHEVRON_SIZE).flexShrink(0)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
}
