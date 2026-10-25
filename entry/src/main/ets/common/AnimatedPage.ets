import { FrameCallback } from '@kit.ArkUI';
import { Motion } from './Theme';

class PageEnterFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(): void { this.action(); }
}

// Keep the outgoing page alive until its exit finishes. A new request invalidates old callbacks.
@Component
export struct AnimatedPage {
  @Prop @Watch('visibilityChanged') visible: boolean = false;
  @Prop @Watch('retentionChanged') retained: boolean = false;
  @Prop vertical: boolean = false;
  @BuilderParam content: () => void;
  onPresenceChanged: (present: boolean) => void = () => {};
  @State private renderContent: boolean = false;
  @State private present: boolean = false;
  @State private progress: number = 0;
  private generation: number = 0;
  aboutToAppear(): void {
    this.renderContent = this.retained;
    this.visibilityChanged();
  }
  aboutToDisappear(): void { this.generation++; }
  private retentionChanged(): void {
    if (!this.present) { this.renderContent = this.retained; }
  }
  private visibilityChanged(): void {
    const generation = ++this.generation;
    if (this.visible) {
      const entering = !this.present;
      this.renderContent = true; this.present = true;
      this.onPresenceChanged(true);
      // The first frame must actually paint at progress=0 before animating a newly mounted page.
      if (entering) {
        this.getUIContext().postFrameCallback(new PageEnterFrame(() => {
          if (generation === this.generation && this.visible) { this.animate(true, generation); }
        }));
      } else { this.animate(true, generation); }
    } else if (this.present) { this.animate(false, generation); }
    else { this.renderContent = this.retained; }
  }
  private animate(show: boolean, generation: number): void {
    this.getUIContext().animateTo({ duration: show ? Motion.medium : Motion.fast,
      curve: show ? Motion.enter : Motion.standard, onFinish: () => {
        if (generation !== this.generation || this.visible) { return; }
        this.present = false; this.renderContent = this.retained;
        this.onPresenceChanged(false);
      } }, () => { this.progress = show ? 1 : 0; });
  }
  build() {
    Stack() {
      if (this.renderContent) { this.content() }
    }.width('100%').height('100%')
      .opacity(this.progress)
      .translate({ x: this.vertical ? 0 : (1 - this.progress) * 24, y: this.vertical ? (1 - this.progress) * 24 : 0 })
      .visibility(this.present ? Visibility.Visible : Visibility.Hidden)
      .enabled(this.visible).hitTestBehavior(this.visible ? HitTestMode.Default : HitTestMode.None)
      .accessibilityLevel(this.visible ? 'auto' : 'no-hide-descendants')
  }
}
