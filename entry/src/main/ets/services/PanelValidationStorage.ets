import { MiniAppStorage, MiniAppSnapshot } from '../model/MiniApp';
import { validatePanelViewState } from '../model/LifePanel';

// Each validation width gets its own detached state. Tests never write live card data.
export class PanelValidationStorage implements MiniAppStorage {
  private snapshot: MiniAppSnapshot;
  private sequence: number = 0;
  constructor(initial: MiniAppSnapshot) { this.snapshot = JSON.parse(JSON.stringify(initial)) as MiniAppSnapshot; }
  async load(): Promise<MiniAppSnapshot> { return JSON.parse(JSON.stringify(this.snapshot)) as MiniAppSnapshot; }
  async save(value: Object | null, revision: string): Promise<MiniAppSnapshot> {
    if (revision !== this.snapshot.revision) { throw new Error('Test state revision conflict'); }
    const next: MiniAppSnapshot = { value: value, revision: 'test-' + (++this.sequence) };
    validatePanelViewState(next); this.snapshot = JSON.parse(JSON.stringify(next)) as MiniAppSnapshot;
    return this.load();
  }
}
