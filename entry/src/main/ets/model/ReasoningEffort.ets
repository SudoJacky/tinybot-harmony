import { t } from './I18n';

// Standard wire values. "default" is a local sentinel and is never sent to a provider.
// Model-specific subsets verified against official docs; see docs/reasoning-effort.md.
export const REASONING_EFFORTS: string[] = ['default', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

export function reasoningEfforts(protocol: string, model: string = ''): string[] {
  const name = model.toLowerCase().split('/').pop() || '';
  if (protocol === 'anthropic-messages') {
    const claude = name.replace(/\./g, '-');
    if (/claude-opus-4-5(?:-|$)/.test(claude)) return ['default', 'low', 'medium', 'high'];
    if (/claude-(opus|sonnet)-4-6(?:-|$)|claude-mythos-preview(?:-|$)/.test(claude)) {
      return ['default', 'low', 'medium', 'high', 'max'];
    }
    if (/claude-(opus-4-[78]|opus-5|sonnet-5|fable-5|mythos-5)(?:-|$)/.test(claude)) {
      return ['default', 'low', 'medium', 'high', 'xhigh', 'max'];
    }
    // Older Claude models expose a token budget, not standard effort levels.
    if (/claude-(?:haiku|sonnet|opus|[123])/.test(claude)) return ['default'];
    // Custom gateway aliases use the protocol's standard values; the gateway resolves the model.
    return ['default', 'low', 'medium', 'high', 'xhigh', 'max'];
  }
  if (protocol !== 'chat-completions' && protocol !== 'responses') return ['default'];
  if (/^gpt-6(?:\.|-)/.test(name)) {
    return /(?:astra|6\.1-sol)/.test(name) ? ['default', 'low', 'medium', 'high', 'xhigh', 'max'] :
      ['default', 'none', 'low', 'medium', 'high', 'xhigh', 'max'];
  }
  if (/^gpt-5-pro(?:-|$)/.test(name)) return ['default', 'high'];
  if (/^gpt-5\.[245]-pro(?:-|$)/.test(name)) return ['default', 'medium', 'high', 'xhigh'];
  if (/^gpt-5.*codex/.test(name)) {
    return /5\.1-codex-max|5\.[2-5]/.test(name) ? ['default', 'low', 'medium', 'high', 'xhigh'] : ['default', 'low', 'medium', 'high'];
  }
  if (/^gpt-5\.1(?:-|$)/.test(name)) return ['default', 'none', 'low', 'medium', 'high'];
  if (/^gpt-5\.[245](?:-|$)/.test(name)) return ['default', 'none', 'low', 'medium', 'high', 'xhigh'];
  if (/^gpt-5(?:-|$)/.test(name)) return ['default', 'minimal', 'low', 'medium', 'high'];
  if (/^o[134](?:-|$)/.test(name)) return ['default', 'low', 'medium', 'high'];
  if (/^gpt-(?:4|3\.5)/.test(name)) return ['default'];
  return REASONING_EFFORTS.slice();
}

export function supportsReasoningEffort(protocol: string, model: string = ''): boolean {
  return reasoningEfforts(protocol, model).length > 1;
}

export function isHighestReasoningEffort(protocol: string, model: string, effort: string): boolean {
  const levels = reasoningEfforts(protocol, model);
  return effort !== 'default' && levels.length > 1 && effort === levels[levels.length - 1];
}

export function adaptiveThinkingModel(model: string): boolean {
  return /claude-(?:(?:opus|sonnet)-4-[678]|(?:opus|sonnet|fable|mythos)-5|mythos-preview)(?:-|$)/
    .test(model.toLowerCase().replace(/\./g, '-'));
}

export function reasoningEffortName(value: string): string {
  return value === 'default' ? t('默认') : value;
}
