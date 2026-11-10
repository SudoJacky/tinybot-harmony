import { KeyCode } from '@kit.InputKit';
import { t } from '../model/I18n';

export type NavigationShortcut = 'new-chat' | 'search' | 'history' | 'settings' | 'workspace' | 'help';
export type ChatShortcutAction = NavigationShortcut | 'focus' | 'attach' | 'expand' | 'latest' | 'stop';

export interface ChatShortcut {
  action: ChatShortcutAction;
  key: string | FunctionKey;
  modifiers: ModifierKey[];
  chord: string;
  label: string;
}

export function chatShortcuts(): ChatShortcut[] {
  const ctrl = [ModifierKey.CTRL];
  const ctrlShift = [ModifierKey.CTRL, ModifierKey.SHIFT];
  return [
    { action: 'new-chat', key: 'n', modifiers: ctrl, chord: 'Ctrl+N', label: t('新建对话') },
    { action: 'search', key: 'k', modifiers: ctrl, chord: 'Ctrl+K', label: t('搜索对话') },
    { action: 'history', key: 'b', modifiers: ctrl, chord: 'Ctrl+B', label: t('展开或收起对话列表') },
    { action: 'settings', key: ',', modifiers: ctrl, chord: 'Ctrl+,', label: t('设置') },
    { action: 'workspace', key: 'f', modifiers: ctrlShift, chord: 'Ctrl+Shift+F', label: t('工作区文件') },
    { action: 'focus', key: 'l', modifiers: ctrlShift, chord: 'Ctrl+Shift+L', label: t('聚焦消息输入框') },
    { action: 'attach', key: 'o', modifiers: ctrl, chord: 'Ctrl+O', label: t('添加文件附件') },
    { action: 'expand', key: 'e', modifiers: ctrlShift, chord: 'Ctrl+Shift+E', label: t('展开输入') },
    { action: 'latest', key: 'j', modifiers: ctrlShift, chord: 'Ctrl+Shift+J', label: t('查看最新消息') },
    { action: 'stop', key: 's', modifiers: ctrlShift, chord: 'Ctrl+Shift+S', label: t('停止生成') },
    { action: 'help', key: FunctionKey.F1, modifiers: [], chord: 'F1', label: t('键盘快捷键') }
  ];
}

export function handleDraftEnter(event: KeyEvent, editor: TextAreaController, composing: boolean, send: () => void): boolean {
  if (event.type !== KeyType.Down || (event.keyCode !== KeyCode.KEYCODE_ENTER && event.keyCode !== KeyCode.KEYCODE_NUMPAD_ENTER) ||
    composing || event.metaKey || event.getModifierKeyState?.(['Shift'])) { return false; }
  const ctrl = event.getModifierKeyState?.(['Ctrl']);
  const alt = event.getModifierKeyState?.(['Alt']);
  if (ctrl && !alt) {
    const selection = editor.getSelection();
    const start = selection.start ?? 0;
    const end = selection.end ?? start;
    if (start !== end) { editor.deleteText(selection); }
    editor.addText('\n', { offset: start });
    return true;
  }
  if (alt && !ctrl) { send(); return true; }
  return false;
}
