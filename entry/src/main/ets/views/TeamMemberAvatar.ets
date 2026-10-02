// Sprite and ID mapping from Tinybot desktop's TeamMemberAvatar.
// The unchanged 4 x 3 portrait sheet is bundled locally; see docs/licenses/tinybot-MIT.txt.
function portraitIndex(memberId: string): number {
  if (memberId === 'research') { return 0; }
  if (memberId === 'analysis') { return 4; }
  if (memberId === 'editor') { return 7; }
  let hash = 0;
  // Team IDs are ASCII. Match desktop's unsigned 32-bit hash, independent of name or order.
  for (let index = 0; index < memberId.length; index++) {
    hash = (hash * 31 + memberId.charCodeAt(index)) >>> 0;
  }
  return hash % 12;
}

@Component
export struct TeamMemberAvatar {
  @Prop memberId: string = '';
  @Prop diameter: number = 32;
  @Prop ring: boolean = false;
  @Prop busy: boolean = false;
  @Prop label: string = '';

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Image($r('app.media.team_employee_portraits'))
          .width(this.diameter * 4).height(this.diameter * 3).objectFit(ImageFit.Fill)
          .interpolation(ImageInterpolation.None).draggable(false)
          .position({ x: -(portraitIndex(this.memberId) % 4) * this.diameter,
            y: -Math.floor(portraitIndex(this.memberId) / 4) * this.diameter })
          .accessibilityLevel('no')
      }.width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2).clip(true)
      // Draw the status ring over the cropped image so it never shifts the sprite coordinates.
      Circle().width(this.diameter).height(this.diameter).fill(Color.Transparent)
        .stroke(this.busy ? $r('app.color.accent') : $r('app.color.surface'))
        .strokeWidth(this.ring ? 2 : 0).accessibilityLevel('no')
    }.width(this.diameter).height(this.diameter).accessibilityText(this.label).accessibilityGroup(true)
  }
}
