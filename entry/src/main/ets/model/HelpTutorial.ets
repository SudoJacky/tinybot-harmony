// Local, read-only walkthroughs. Coordinates use the same 360vp page layout as HelpTutorialScreen.
export type HelpDemoKind = 'chat' | 'attachments' | 'preferences' | 'backup' | 'failure' |
  'prepare' | 'model' | 'task' | 'results';
export type TutorialScreen = 'chat' | 'chat-v4' | 'draft' | 'answer' | 'running' | 'speech' | 'attachment' | 'error' | 'team' |
  'menu' | 'plus' | 'models' | 'settings' | 'settings-memory' | 'settings-data' | 'presets' |
  'provider' | 'provider-ready' | 'document' | 'document-ready' | 'memory' | 'backup' | 'files';
export type TutorialControl = 'more' | 'settings' | 'add-provider' | 'deepseek' | 'key' | 'save-provider' |
  'get-key' | 'model-picker' | 'model-choice' | 'composer' | 'send' | 'plus' | 'photo' | 'mic' |
  'stop' | 'user-document' | 'save-document' | 'memory' | 'backup' | 'cloud-backup' | 'export-backup' |
  'files' | 'export' | 'retry' | 'provider-existing' | 'document-input' | 'team';
export interface TutorialRect { x: number; y: number; width: number; height: number; }
export interface TutorialStep {
  screen: TutorialScreen;
  after: TutorialScreen;
  control: TutorialControl;
  caption: string;
}

export const TUTORIAL_WIDTH: number = 360;
export const TUTORIAL_HEIGHT: number = 720;
export const TUTORIAL_STEP_MS: number = 1900;

// Editing or receiving a message changes content within the same page; only navigation slides a page.
export function tutorialPage(screen: TutorialScreen): string {
  if (screen === 'chat' || screen === 'chat-v4' || screen === 'draft' || screen === 'answer' || screen === 'running' ||
    screen === 'speech' || screen === 'attachment' || screen === 'error' || screen === 'team' || screen === 'menu' || screen === 'plus') {
    return 'chat';
  }
  if (screen === 'provider-ready') { return 'provider'; }
  if (screen === 'document-ready') { return 'document'; }
  if (screen === 'settings-memory' || screen === 'settings-data' || screen === 'presets') { return 'settings'; }
  return screen;
}

// Shared by the renderer and click choreography, so the pointer cannot drift from its control.
export function tutorialRect(control: TutorialControl): TutorialRect {
  switch (control) {
    case 'more': return { x: 264, y: 28, width: 44, height: 44 };
    case 'model-picker': return { x: 54, y: 28, width: 202, height: 44 };
    case 'composer': return { x: 58, y: 642, width: 242, height: 44 };
    case 'plus': return { x: 26, y: 648, width: 36, height: 36 };
    case 'mic': return { x: 298, y: 648, width: 36, height: 36 };
    case 'send': case 'stop': return { x: 298, y: 648, width: 36, height: 36 };
    case 'settings': return { x: 108, y: 352, width: 200, height: 44 };
    case 'files': return { x: 108, y: 132, width: 200, height: 44 };
    case 'export': return { x: 108, y: 308, width: 200, height: 44 };
    case 'add-provider': return { x: 16, y: 196, width: 328, height: 56 };
    case 'provider-existing': return { x: 16, y: 132, width: 328, height: 64 };
    case 'deepseek': return { x: 16, y: 138, width: 328, height: 56 };
    case 'key': return { x: 28, y: 450, width: 304, height: 48 };
    case 'get-key': return { x: 100, y: 508, width: 160, height: 40 };
    case 'save-provider': case 'save-document': return { x: 16, y: 652, width: 328, height: 48 };
    case 'model-choice': return { x: 16, y: 160, width: 328, height: 60 };
    case 'photo': return { x: 24, y: 438, width: 56, height: 80 };
    case 'team': return { x: 280, y: 438, width: 56, height: 80 };
    case 'user-document': return { x: 16, y: 348, width: 328, height: 64 };
    case 'memory': return { x: 16, y: 228, width: 328, height: 64 };
    case 'document-input': return { x: 16, y: 148, width: 328, height: 472 };
    case 'backup': return { x: 16, y: 192, width: 328, height: 56 };
    case 'cloud-backup': return { x: 16, y: 132, width: 328, height: 80 };
    case 'export-backup': return { x: 16, y: 408, width: 328, height: 64 };
    case 'retry': return { x: 16, y: 598, width: 154, height: 32 };
  }
}

export function tutorialResultRect(step: TutorialStep): TutorialRect {
  if (step.control === 'photo') { return { x: 20, y: 588, width: 160, height: 40 }; }
  if (step.control === 'composer') { return { x: 32, y: 590, width: 296, height: 48 }; }
  if (step.control === 'send') { return { x: 86, y: 114, width: 258, height: 80 }; }
  if (step.control === 'model-choice') { return tutorialRect('model-picker'); }
  if (step.control === 'save-provider') { return tutorialRect('provider-existing'); }
  if (step.control === 'save-document') { return tutorialRect('user-document'); }
  return tutorialRect(step.control);
}

function step(screen: TutorialScreen, control: TutorialControl, after: TutorialScreen, caption: string): TutorialStep {
  return { screen, control, after, caption };
}

export function tutorialSteps(kind: HelpDemoKind): TutorialStep[] {
  switch (kind) {
    case 'chat': return [
      step('chat-v4', 'model-picker', 'models', '点击顶部选择模型'),
      step('models', 'model-choice', 'chat', '选择要使用的模型'),
      step('chat', 'composer', 'draft', '输入你的问题'),
      step('draft', 'send', 'answer', '输入问题并发送')
    ];
    case 'model': return [
      step('chat', 'more', 'menu', '点击右上角更多操作'),
      step('menu', 'settings', 'settings', '打开设置'),
      step('settings', 'add-provider', 'presets', '点击添加模型服务'),
      step('presets', 'deepseek', 'provider', '选择服务商'),
      step('provider', 'key', 'provider-ready', '填写 API Key'),
      step('provider-ready', 'save-provider', 'settings', '保存服务')
    ];
    case 'prepare': return [
      step('settings', 'add-provider', 'presets', '点击添加模型服务'),
      step('presets', 'deepseek', 'provider', '选择服务商'),
      step('provider', 'get-key', 'provider', '获取 API Key，在浏览器中打开')
    ];
    case 'attachments': return [
      step('chat', 'plus', 'plus', '点击输入框左侧的 +'),
      step('plus', 'photo', 'attachment', '点击图片，选择要添加的材料'),
      step('chat', 'mic', 'speech', '点击麦克风开始录音'),
      step('speech', 'mic', 'draft', '再次点击结束语音输入'),
      step('draft', 'send', 'answer', '检查文字后手动发送')
    ];
    case 'preferences': return [
      step('settings-memory', 'user-document', 'document', '打开用户文档'),
      step('document', 'document-input', 'document-ready', '填写称呼和回答偏好'),
      step('document-ready', 'save-document', 'settings-memory', '填写偏好并保存'),
      step('settings-memory', 'memory', 'memory', '查看和管理记忆')
    ];
    case 'backup': return [
      step('chat', 'more', 'menu', '点击右上角更多操作'),
      step('menu', 'files', 'files', '打开会话文件'),
      step('settings-data', 'backup', 'backup', '向下滚动设置，打开备份与恢复'),
      step('backup', 'export-backup', 'backup', '导出备份')
    ];
    case 'failure': return [
      step('settings', 'provider-existing', 'provider-ready', '检查地址、密钥和模型'),
      step('provider-ready', 'save-provider', 'settings', '保存更正后的服务配置'),
      step('error', 'retry', 'draft', '点击重新编辑并发送'),
      step('draft', 'send', 'answer', '修改后重试')
    ];
    case 'task': return [
      step('chat', 'composer', 'draft', '输入你的问题'),
      step('draft', 'send', 'running', '输入问题并发送'),
      step('running', 'stop', 'answer', '发送后可随时停止'),
      step('answer', 'plus', 'plus', '点击输入框左侧的 +'),
      step('plus', 'team', 'team', 'Agent 团队')
    ];
    case 'results': return [
      step('answer', 'more', 'menu', '点击右上角更多操作'),
      step('menu', 'export', 'menu', '从更多菜单导出对话'),
      step('settings-data', 'backup', 'backup', '向下滚动设置，打开备份与恢复'),
      step('backup', 'cloud-backup', 'backup', '备份到华为云空间')
    ];
  }
}

export function tutorialEase(value: number): number {
  const unit = Math.max(0, Math.min(1, value));
  return unit * unit * (3 - 2 * unit);
}
