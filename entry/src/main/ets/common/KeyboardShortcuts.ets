import { KeyCode } from '@kit.InputKit';
import { t } from '../model/I18n';

export type NavigationShortcut = 'new-chat' | 'search' | 'history' | 'settings' | 'workspace' | 'help';
export type ChatShortcutAction = NavigationShortcut | 'focus' | 'attach' | 'expand' | 'latest' | 'stop';

type ShortcutCategory = 'chat' | 'navigation' | 'input';

export interface ShortcutHint {
  chord: string;
  label: string;
}

export interface ChatShortcut extends ShortcutHint {
  action: ChatShortcutAction;
  key: string | FunctionKey;
  modifiers: ModifierKey[];
  category: ShortcutCategory;
}

export interface ShortcutGroup {
  category: ShortcutCategory;
  label: string;
  shortcuts: ShortcutHint[];
}

export function chatShortcuts(desktop: boolean = false): ChatShortcut[] {
  const ctrl = [ModifierKey.CTRL];
  const ctrlShift = [ModifierKey.CTRL, ModifierKey.SHIFT];
  return [
    { action: 'new-chat', key: 'n', modifiers: ctrl, chord: 'Ctrl+N', category: 'chat', label: t('新建对话') },
    { action: 'search', key: 'k', modifiers: ctrl, chord: 'Ctrl+K', category: 'navigation',
      label: desktop ? t('搜索对话或命令') : t('搜索对话') },
    { action: 'history', key: 'b', modifiers: ctrl, chord: 'Ctrl+B', category: 'navigation', label: t('展开或收起对话列表') },
    { action: 'settings', key: ',', modifiers: ctrl, chord: 'Ctrl+,', category: 'navigation', label: t('设置') },
    { action: 'workspace', key: 'f', modifiers: ctrlShift, chord: 'Ctrl+Shift+F', category: 'navigation', label: t('工作区文件') },
    { action: 'focus', key: 'l', modifiers: ctrlShift, chord: 'Ctrl+Shift+L', category: 'input', label: t('聚焦消息输入框') },
    { action: 'attach', key: 'o', modifiers: ctrl, chord: 'Ctrl+O', category: 'input', label: t('添加文件附件') },
    { action: 'expand', key: 'e', modifiers: ctrlShift, chord: 'Ctrl+Shift+E', category: 'input', label: t('展开输入') },
    { action: 'latest', key: 'j', modifiers: ctrlShift, chord: 'Ctrl+Shift+J', category: 'chat', label: t('查看最新消息') },
    { action: 'stop', key: 's', modifiers: ctrlShift, chord: 'Ctrl+Shift+S', category: 'chat', label: t('停止生成') },
    { action: 'help', key: FunctionKey.F1, modifiers: [], chord: 'F1', category: 'navigation', label: t('键盘快捷键') }
  ];
}

export function shortcutGroups(query: string, desktop: boolean = false): ShortcutGroup[] {
  const shortcuts = chatShortcuts(desktop);
  const input: ShortcutHint[] = shortcuts.filter((item) => item.category === 'input');
  input.push({ chord: 'Ctrl+Enter', label: t('在消息输入框中换行') }, { chord: 'Alt+Enter', label: t('发送') });
  const groups: ShortcutGroup[] = [
    { category: 'chat', label: t('对话'), shortcuts: shortcuts.filter((item) => item.category === 'chat') },
    { category: 'navigation', label: t('导航'), shortcuts: shortcuts.filter((item) => item.category === 'navigation') },
    { category: 'input', label: t('输入'), shortcuts: input }
  ];
  const terms = query.trim().toLowerCase().replace(/\s*\+\s*/g, '+').split(/\s+/);
  for (const group of groups) {
    group.shortcuts = group.shortcuts.filter((item) => {
      const searchable = (item.label + ' ' + item.chord + ' ' + group.label).toLowerCase();
      return terms.every((term) => searchable.includes(term));
    });
  }
  return groups.filter((group) => group.shortcuts.length > 0);
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
