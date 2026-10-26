import { t } from './I18n';
import { ModelConfig } from './Conversation';

export const DEFAULT_CONTEXT_WINDOW: number = 200000;
// Tinybot desktop: src-tauri/src/agent/provider/model-defaults.json.
const MILLION_TOKEN_MODELS: string[] = ['deepseek-flash', 'deepseek-v4-flash', 'deepseek-v4-flash-vision-exp',
  'deepseek-v4-pro', 'glm-5.3', 'glm-5.3-flash'];
// Used only when neither the model nor its service has an explicit override.
export function defaultContextWindow(model: string): number {
  return MILLION_TOKEN_MODELS.includes(model.trim().toLowerCase()) ? 1000000 : DEFAULT_CONTEXT_WINDOW;
}
// pi coding-agent compaction defaults. Small windows retain usable input space.
export const DEFAULT_CONTEXT_RESERVE: number = 16384;
export const DEFAULT_KEEP_RECENT: number = 20000;
export const SUMMARY_MAX_TOKENS: number = 4096;
export function contextInputBudget(window: number): number {
  return window - Math.min(DEFAULT_CONTEXT_RESERVE, Math.floor(window / 2));
}

export interface ContextSettings {
  window: number;
  autoCompact: boolean;
  keepRecent: number;
}

export function contextSettings(config: ModelConfig): ContextSettings {
  const window = config.contextWindow === undefined ? defaultContextWindow(config.model) : config.contextWindow;
  const autoCompact = config.autoCompact === undefined ? true : config.autoCompact;
  if (!Number.isInteger(window) || window < 8192 || window > 2000000 || typeof autoCompact !== 'boolean') {
    throw new Error(t("上下文窗口必须是 8192 至 2000000 的整数，自动压缩设置必须是布尔值。"));
  }
  return { window: window, autoCompact: autoCompact, keepRecent: Math.min(DEFAULT_KEEP_RECENT, Math.floor(window / 4)) };
}
