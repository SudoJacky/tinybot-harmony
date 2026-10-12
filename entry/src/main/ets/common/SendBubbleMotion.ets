import { curves, FrameCallback } from '@kit.ArkUI';

export interface SendOrigin {
  x: number;
  y: number;
  height: number;
  viewportHeight: number;
}

export class SendFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(): void { this.action(); }
}

@Builder
function emptyBubble() {}

// Move the real bubble, so its text, attachments and final layout never need a duplicate.
@Component
export struct SendBubbleMotion {
  @Prop origin: SendOrigin | undefined = undefined;
  @Prop bubbleId: string = '';
  @BuilderParam content: () => void = emptyBubble;
  onReady: () => void = () => {};
  onFinish: () => void = () => {};
  @State private shiftX: number = 0;
  @State private shiftY: number = 0;
  @State private bubbleScale: number = 1;
  @State private alpha: number = 1;
  private mounted: boolean = false;
  private started: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.alpha = this.origin ? 0 : 1;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    if (this.origin) { this.onFinish(); }
  }

  private launch(): void {
    const origin = this.origin;
    if (!origin || this.started) { return; }
    this.started = true;
    this.onReady();
    const context = this.getUIContext();
    // First finish the List's scroll/layout, then present the origin before animating away.
    context.postFrameCallback(new SendFrame(() => {
      context.postFrameCallback(new SendFrame(() => {
        if (!this.mounted) { return; }
        const rect = context.getComponentUtils().getRectangleById(this.bubbleId);
        const width = context.px2vp(rect.size.width);
        const height = context.px2vp(rect.size.height);
        if (width <= 0 || height <= 0) { this.alpha = 1; this.onFinish(); return; }
        // Very tall messages stay readable instead of flying a screen-sized block across the UI.
        const compact = height < origin.viewportHeight * 0.8;
        this.shiftX = compact ? origin.x - context.px2vp(rect.windowOffset.x) - width / 2 : 0;
        this.shiftY = compact ? origin.y - context.px2vp(rect.windowOffset.y) - height / 2 : 20;
        this.bubbleScale = compact ? Math.max(0.78, Math.min(0.94, origin.height / height)) : 1;
        this.alpha = 0.72;
        context.postFrameCallback(new SendFrame(() => {
          if (!this.mounted) { return; }
          context.animateTo({ curve: curves.springMotion(0.35, 0.86), onFinish: () => {
            if (this.mounted) { this.onFinish(); }
          } }, () => { this.shiftX = 0; this.shiftY = 0; this.bubbleScale = 1; this.alpha = 1; });
        }));
      }));
    }));
  }

  build() {
    Column({ space: 6 }) { this.content() }
      .id(this.bubbleId).constraintSize({ maxWidth: '100%' }).alignItems(HorizontalAlign.End)
      .translate({ x: this.shiftX, y: this.shiftY }).scale({ x: this.bubbleScale, y: this.bubbleScale })
      .opacity(this.alpha).onAreaChange(() => this.launch())
  }
}
