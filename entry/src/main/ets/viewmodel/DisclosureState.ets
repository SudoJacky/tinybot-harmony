// Transient reading state belongs to a message, not to conditionally mounted UI.
@Observed
export class DisclosureState {
  open: boolean = false;
  limit: number = 0;
  rawOpen: boolean = false;
  rawLimit: number = 2000;
}

export class DisclosureStore {
  private entries: Map<string, DisclosureState> = new Map<string, DisclosureState>();

  get(key: string): DisclosureState {
    let state = this.entries.get(key);
    if (!state) {
      state = new DisclosureState();
      this.entries.set(key, state);
    }
    return state;
  }
}
