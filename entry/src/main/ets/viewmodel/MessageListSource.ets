import { MessageViewModel } from './SessionViewModels';

// LazyForEach owns mounted rows; the existing view models retain disclosure and saved UI state.
export class MessageListSource implements IDataSource {
  private messages: MessageViewModel[] = [];
  private threadId: string = '';
  private listeners: DataChangeListener[] = [];
  update(threadId: string, messages: MessageViewModel[]): void {
    if (threadId === this.threadId && messages.length === this.messages.length &&
      messages.every((message, index) => message === this.messages[index])) { return; }
    this.threadId = threadId; this.messages = messages.slice();
    for (const listener of this.listeners) { listener.onDataReloaded(); }
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
