import { WebUiStorage, WebUiSnapshot } from '../model/WebUi';
import { validatePanelViewState } from '../model/LifePanel';

// Each validation width gets its own detached state. Tests never write live card data.
export class PanelValidationStorage implements WebUiStorage {
  private snapshot: WebUiSnapshot;
  private sequence: number = 0;
  constructor(initial: WebUiSnapshot) { this.snapshot = JSON.parse(JSON.stringify(initial)) as WebUiSnapshot; }
  async load(): Promise<WebUiSnapshot> { return JSON.parse(JSON.stringify(this.snapshot)) as WebUiSnapshot; }
  async save(value: Object | null, revision: string): Promise<WebUiSnapshot> {
    if (revision !== this.snapshot.revision) { throw new Error('Test state revision conflict'); }
    const next: WebUiSnapshot = { value: value, revision: 'test-' + (++this.sequence) };
    validatePanelViewState(next); this.snapshot = JSON.parse(JSON.stringify(next)) as WebUiSnapshot;
    return this.load();
  }
}
