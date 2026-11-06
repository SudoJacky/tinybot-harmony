import { WebUiPreflight, WebUiProbe } from '../services/WebUiPreflight';
import { WebUiView } from './WebUiView';

@Component
export struct WebUiPreflightHost {
  @State private probes: WebUiProbe[] = [];
  private unsubscribe?: () => void;
  aboutToAppear(): void { this.unsubscribe = WebUiPreflight.subscribe((probes) => { this.probes = probes; }); }
  aboutToDisappear(): void { this.unsubscribe?.(); }
  build() {
    Stack() {
      ForEach(this.probes, (probe: WebUiProbe) => {
        WebUiView({ content: probe.content, values: probe.values, preflight: true, storage: probe.storage, panelContext: probe.panelContext, panelProbe: probe.options,
          onValidation: (error: string) => WebUiPreflight.complete(probe.id, error) }).width(probe.options?.width || '100%')
      }, (probe: WebUiProbe) => String(probe.id))
    }.width('100%').height(800).opacity(0).hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}
