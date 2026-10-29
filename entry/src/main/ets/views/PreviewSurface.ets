import { BuilderNode, FrameNode, NodeController, UIContext, typeNode } from '@kit.ArkUI';
import { PublishedPreview } from '../model/PublishedPreview';
import { UiSavedState, UiValues } from '../model/InteractiveUi';
import { UiPresentation } from '../model/UiPresentation';
import { Diagnostics } from '../model/Diagnostics';
import { InteractiveAnswer } from './InteractiveAnswer';

export class PreviewSurfaceOptions {
  preview: PublishedPreview;
  saved: UiSavedState[] = [];
  presentation?: UiPresentation;
  available: boolean = false;
  frameless: boolean = false;
  viewportHeight: number = 0;
  onInteract: (key: string, values: UiValues, action: string) => Promise<UiValues> = async () => { throw new Error('Preview interaction handler missing'); };
  constructor(preview: PublishedPreview) { this.preview = preview; }
}

// moveTo supports BuilderNode roots of type Stack. Keep this root stable across both hosts.
@Builder
function previewSurfaceBuilder(options: PreviewSurfaceOptions) {
  Stack() {
    InteractiveAnswer({ content: options.preview.content, step: options.preview.step, surfaceOffset: options.preview.surfaceOffset,
      allowSurface: !/\.jsonl$/i.test(options.preview.path), frameless: options.frameless, viewportHeight: options.viewportHeight,
      saved: options.saved, presentation: options.presentation, available: options.available, selectable: false, onInteract: options.onInteract })
  }.width('100%')
}

class PreviewSurfaceMount extends NodeController {
  private owner: PreviewSurface;
  private fullscreen: boolean;
  private root?: FrameNode;
  private context?: UIContext;
  constructor(owner: PreviewSurface, fullscreen: boolean) { super(); this.owner = owner; this.fullscreen = fullscreen; }
  makeNode(context: UIContext): FrameNode | null {
    const root = typeNode.createNode(context, 'Stack');
    root.commonAttribute.width('100%');
    this.root = root;
    this.context = context;
    this.owner.prepare(context);
    return root;
  }
  aboutToAppear(): void {
    if (!this.root || !this.context) { throw new Error('Preview host was not created'); }
    // LazyForEach may reattach a cached host without calling makeNode again.
    // Its renderer was released on disappearance, so restore it before mounting.
    this.owner.prepare(this.context);
    // Move only after the target host has entered the live tree.
    this.owner.attach(this.root, this.fullscreen);
  }
  aboutToDisappear(): void { this.owner.detach(this.fullscreen); }
}

// Owned by one chat card, never persisted or shared between chats. One builder owns the live page.
export class PreviewSurface {
  readonly inlineMount: NodeController = new PreviewSurfaceMount(this, false);
  readonly fullscreenMount: NodeController = new PreviewSurfaceMount(this, true);
  private builder?: BuilderNode<[PreviewSurfaceOptions]>;
  private options?: PreviewSurfaceOptions;
  private inlineRoot?: FrameNode;
  private fullscreenRoot?: FrameNode;
  private fullscreen: boolean = false;
  private disposed: boolean = false;
  private inlineFrameless: boolean = false;
  setOptions(options: PreviewSurfaceOptions): void {
    this.inlineFrameless = options.frameless;
    options.viewportHeight = this.fullscreen ? this.options?.viewportHeight || 0 : 0;
    options.frameless = this.fullscreen || this.inlineFrameless;
    this.options = options; this.builder?.update(options);
  }
  prepare(context: UIContext): void {
    if (this.disposed) { throw new Error('Preview surface was disposed'); }
    if (!this.options) { throw new Error('Preview surface options are missing'); }
    if (!this.builder) {
      this.builder = new BuilderNode<[PreviewSurfaceOptions]>(context);
      this.builder.build(wrapBuilder<[PreviewSurfaceOptions]>(previewSurfaceBuilder), this.options);
    }
  }
  attach(root: FrameNode, fullscreen: boolean): void {
    if (fullscreen) { this.fullscreenRoot = root; }
    else { this.inlineRoot = root; }
    if (fullscreen === this.fullscreen) { this.move(root); }
  }
  enterFullscreen(): void {
    if (this.disposed || !this.builder) { throw new Error('Preview is not mounted'); }
    this.fullscreen = true;
    if (this.options) { this.options.frameless = true; this.builder.update(this.options); }
    if (this.fullscreenRoot) { this.move(this.fullscreenRoot); }
  }
  resizeFullscreen(height: number): void {
    if (!this.fullscreen || !this.options || this.disposed) { return; }
    this.options.viewportHeight = height; this.builder?.update(this.options);
  }
  exitFullscreen(): void {
    if (!this.fullscreen || this.disposed) { return; }
    this.fullscreen = false;
    if (this.options) {
      this.options.viewportHeight = 0; this.options.frameless = this.inlineFrameless;
      this.builder?.update(this.options);
    }
    // Restore the same subtree before the fullscreen host is removed.
    if (this.inlineRoot) { this.move(this.inlineRoot); }
    else { this.release(); }
  }
  detach(fullscreen: boolean): void {
    if (fullscreen) { this.exitFullscreen(); this.fullscreenRoot = undefined; }
    else { this.inlineRoot = undefined; if (!this.fullscreen) { this.release(); } }
  }
  private move(root: FrameNode): void {
    const frame = this.builder?.getFrameNode();
    if (!frame) { throw new Error('Preview surface has no frame'); }
    if (frame.getParent() === root) { return; }
    try {
      if (frame.getParent()) { frame.moveTo(root); } else { root.appendChild(frame); }
    } catch (error) {
      Diagnostics.log('error', 'preview', 'failed', { previewId: this.options?.preview.id, enabled: this.fullscreen }, error as Error);
      throw error as Error;
    }
    Diagnostics.log('debug', 'preview', 'surface_moved', { previewId: this.options?.preview.id, enabled: this.fullscreen });
  }
  private release(): void { this.builder?.dispose(); this.builder = undefined; }
  dispose(): void {
    if (this.disposed) { return; }
    this.disposed = true; this.release(); this.inlineRoot = undefined; this.fullscreenRoot = undefined;
  }
}
