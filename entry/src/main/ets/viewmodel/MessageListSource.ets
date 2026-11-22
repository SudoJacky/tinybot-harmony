import { MessageViewModel } from './SessionViewModels';

// LazyForEach owns mounted rows; the existing view models retain disclosure and saved UI state.
export class MessageListSource implements IDataSource {
  private messages: MessageViewModel[] = [];
  private start: number = 0;
  private threadId: string = '';
  private listeners: DataChangeListener[] = [];
  // ThreadViewModel replaces the array when its message membership changes.
  update(threadId: string, messages: MessageViewModel[], limit: number = messages.length): void {
    const start = Math.max(0, messages.length - limit);
    const sameThread = threadId === this.threadId;
    if (sameThread && this.messages === messages && this.start === start) { return; }
    const previousCount = this.totalCount();
    const added = messages.length - start - previousCount;
    let operation: DataOperation = { type: DataOperationType.RELOAD };
    if (sameThread && added >= 0) {
      const samePrefix = this.matches(messages, start);
      if (added === 0 && samePrefix) {
        this.messages = messages; this.start = start;
        return;
      }
      if (added > 0) {
        if (samePrefix) {
          operation = { type: DataOperationType.ADD, index: previousCount, count: added };
        } else if (this.matches(messages, start + added)) {
          // Older history extends the front of the same list. Retain the visible rows and their position.
          operation = { type: DataOperationType.ADD, index: 0, count: added };
        }
      }
    }
    this.threadId = threadId; this.messages = messages; this.start = start;
    for (const listener of this.listeners) { listener.onDatasetChange([operation]); }
  }
  private matches(messages: MessageViewModel[], start: number): boolean {
    if (this.messages === messages && this.start === start) { return true; }
    for (let index = 0; index < this.totalCount(); index++) {
      if (this.messages[this.start + index] !== messages[start + index]) { return false; }
    }
    return true;
  }
  totalCount(): number { return this.messages.length - this.start; }
  getData(index: number): MessageViewModel | undefined {
    return index < 0 ? undefined : this.messages[this.start + index];
  }
  indexOf(id: string): number {
    for (let i = this.start; i < this.messages.length; i++) {
      if (this.messages[i].id === id) { return i - this.start; }
    }
    return -1;
  }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item) => item !== listener);
  }
}
