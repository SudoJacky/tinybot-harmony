import { PanelSpec } from '../model/LifePanel';
import { Cancellation } from './Cancellation';
export type PanelAgentRunner = (workspaceId: string, id: string, spec: PanelSpec, data: Object, cancellation: Cancellation) => Promise<Object>;
// Installed at native session composition, keeping refresh independent of the source chat.
export class PanelAgentRefresh {
  private static runners: Map<string, PanelAgentRunner> = new Map<string, PanelAgentRunner>();
  static install(root: string, runner: PanelAgentRunner): void { PanelAgentRefresh.runners.set(root, runner); }
  static async run(root: string, id: string, spec: PanelSpec, data: Object, cancellation: Cancellation): Promise<Object> {
    const runner = PanelAgentRefresh.runners.get(root.slice(0, root.lastIndexOf('/')));
    if (!runner) { throw new Error('Agent updates are not ready. Finish loading the app and retry.'); }
    const workspaceId = root.slice(root.lastIndexOf('/') + 1);
    return runner(workspaceId, id, spec, data, cancellation);
  }
}
