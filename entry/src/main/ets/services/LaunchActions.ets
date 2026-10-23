import { Want } from '@kit.AbilityKit';

export type LaunchAction = 'new-chat' | 'voice-input' | 'continue-chat';

// Keep the latest explicit launch intent until both the foreground and loaded page can receive it.
export class LaunchActions {
  private static pending?: LaunchAction;
  private static foreground: boolean = false;
  private static listener?: () => void;

  static receive(want: Want): void {
    const action = want.parameters?.['tinybotAction'];
    if (action !== 'new-chat' && action !== 'voice-input' && action !== 'continue-chat') { return; }
    LaunchActions.pending = action as LaunchAction;
    LaunchActions.notify();
  }

  static setForeground(foreground: boolean): void {
    LaunchActions.foreground = foreground;
    LaunchActions.notify();
  }

  static subscribe(listener: () => void): () => void {
    LaunchActions.listener = listener;
    LaunchActions.notify();
    return () => { if (LaunchActions.listener === listener) { LaunchActions.listener = undefined; } };
  }

  static take(): LaunchAction | undefined {
    if (!LaunchActions.foreground) { return undefined; }
    const action = LaunchActions.pending; LaunchActions.pending = undefined; return action;
  }

  static isForeground(): boolean { return LaunchActions.foreground; }

  private static notify(): void {
    if (LaunchActions.foreground && LaunchActions.pending) { LaunchActions.listener?.(); }
  }
}
