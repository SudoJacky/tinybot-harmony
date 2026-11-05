import { PanelEntry, panelDue } from '../model/LifePanel';
import { Diagnostics } from '../model/Diagnostics';
import { LifePanels } from './LifePanels';
import { Cancellation, RunCancelledError } from './Cancellation';
import { PanelChanges } from './PanelChanges';

// One app-level foreground owner; independent of navigation and source chat lifetime.
export class PanelExpiryUpdates {
  private panels: LifePanels;
  private active: boolean = false;
  private scanning: boolean = false;
  private timer: number = -1;
  private cancellation: Cancellation = new Cancellation();
  private unsubscribe?: () => void;
  private rescan: boolean = false;
  constructor(panels: LifePanels) { this.panels = panels; }
  setActive(active: boolean): void {
    if (this.active === active) { return; }
    this.active = active; clearTimeout(this.timer); this.timer = -1; this.cancellation.cancel(); this.unsubscribe?.();
    if (active) {
      this.cancellation = new Cancellation();
      this.unsubscribe = PanelChanges.subscribe(() => { this.rescan = true; if (!this.scanning) { clearTimeout(this.timer); this.scan(); } });
      this.scan();
    }
  }
  private scan(): void {
    if (!this.active) { return; }
    if (this.scanning) { this.timer = setTimeout(() => this.scan(), 1000); return; }
    this.scanning = true;
    this.rescan = false;
    const cancellation = this.cancellation;
    this.panels.list().then(async (entries: PanelEntry[]) => {
      for (const entry of entries) {
        cancellation.check();
        if (!panelDue(entry.panel, Date.now())) { continue; }
        try { await this.panels.repository(entry.workspaceId).refresh(entry.panel.id, cancellation); }
        catch (error) {
          if (cancellation.cancelled) { throw error as Error; }
          if (error instanceof RunCancelledError) { continue; }
          Diagnostics.log('error', 'life-panel', 'expiry_failed', { previewId: entry.panel.id, sessionId: entry.workspaceId }, error as Error);
        }
      }
    }).catch((error: Error) => {
      if (!cancellation.cancelled) { Diagnostics.log('error', 'life-panel', 'expiry_failed', {}, error); }
    }).finally(() => {
      this.scanning = false;
      if (this.active && !cancellation.cancelled) { this.timer = setTimeout(() => this.scan(), this.rescan ? 0 : 30000); }
    });
  }
}
