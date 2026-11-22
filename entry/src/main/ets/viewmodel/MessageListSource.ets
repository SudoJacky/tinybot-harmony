import { MessageViewModel } from './SessionViewModels';

// LazyForEach owns mounted rows; the existing view models retain disclosure and saved UI state.
export class MessageListSource implements IDataSource {
  private messages: MessageViewModel[] = [];
  private threadId: string = '';
  private listeners: DataChangeListener[] = [];
  update(threadId: string, messages: MessageViewModel[]): void {
    const previous = this.messages;
    const added = messages.length - previous.length;
    let operation: DataOperation = { type: DataOperationType.RELOAD };
    if (threadId === this.threadId) {
      const samePrefix = previous.every((message, index) => message === messages[index]);
      if (added === 0 && samePrefix) { return; }
      if (added > 0) {
        if (samePrefix) {
          operation = { type: DataOperationType.ADD, index: previous.length, count: added };
        } else if (previous.every((message, index) => message === messages[added + index])) {
          // Older history extends the front of the same list. Retain the visible rows and their position.
          operation = { type: DataOperationType.ADD, index: 0, count: added };
        }
      }
    }
    this.threadId = threadId; this.messages = messages.slice();
    for (const listener of this.listeners) { listener.onDatasetChange([operation]); }
  }
  totalCount(): number { return this.messages.length; }
  getData(index: number): MessageViewModel { return this.messages[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item) => item !== listener);
  }
}
