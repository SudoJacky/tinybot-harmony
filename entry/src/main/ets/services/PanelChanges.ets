export class PanelChanges {
  private static listeners: Set<() => void> = new Set<() => void>();
  static subscribe(listener: () => void): () => void { PanelChanges.listeners.add(listener); return () => { PanelChanges.listeners.delete(listener); }; }
  static emit(): void { Array.from(PanelChanges.listeners).forEach((listener: () => void) => listener()); }
}
