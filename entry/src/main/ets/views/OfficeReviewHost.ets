import { OfficeLayoutReview, OfficeReviewRequest } from '../services/OfficeLayoutReview';
import { OfficePreview } from './OfficePreview';

@Component
export struct OfficeReviewHost {
  @State private requests: OfficeReviewRequest[] = [];
  private unsubscribe?: () => void;

  aboutToAppear(): void {
    this.unsubscribe = OfficeLayoutReview.subscribe((requests) => { this.requests = requests; });
  }
  aboutToDisappear(): void { this.unsubscribe?.(); }

  build() {
    Column() {
      ForEach(this.requests, (request: OfficeReviewRequest) => {
        OfficePreview({ source: { path: '', threadId: '', format: 'pptx', version: '', encoded: request.encoded },
          onReview: (result: string, error?: Error) => OfficeLayoutReview.complete(request.id, result, error) })
      }, (request: OfficeReviewRequest) => String(request.id))
    }.width('100%').height(this.requests.length ? 120 : 0)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}
