import { image } from '@kit.ImageKit';

export interface DrawingBoardOptions {
  draft: DrawingDraft;
  onClose: () => void;
  onAdd: (pixel: image.PixelMap) => Promise<void>;
}

// Native Pen Kit owns ink and history. The composer only coordinates export and dismissal.
@Observed
export class DrawingDraft {
  saving: boolean = false;
  hasContent: () => boolean = () => false;
  dirty(): boolean { return this.hasContent(); }
}
