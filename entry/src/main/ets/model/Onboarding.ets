import { AppData } from './Conversation';
import { t } from './I18n';

export interface OnboardingTask { title: string; prompt: string; preview: string; icon: string; }

export interface OnboardingExampleColumn { label: string; value: string; }
export interface OnboardingExample { title: string; documentTitle: string; columns: OnboardingExampleColumn[]; }

export function onboardingIntroduction(): string[] {
  return [
    t('嗨，我是 Tiny，你的 AI 小助手。'),
    t('我能陪你做市场调研、规划旅行，也能帮你读懂资料。'),
    t('不用一次想清楚。先说个想法，我陪你把它变成下一步。')
  ];
}

export function onboardingExamples(): OnboardingExample[] {
  return [
    { title: t('市场调研'), documentTitle: t('社区咖啡店 · 调研速览'), columns: [
      { label: t('客群'), value: t('附近上班族') },
      { label: t('需求'), value: t('快速取餐') },
      { label: t('建议'), value: t('早餐咖啡组合') }
    ] },
    { title: t('旅行规划'), documentTitle: t('杭州 · 三天两晚'), columns: [
      { label: t('第 1 天'), value: t('西湖漫步') },
      { label: t('第 2 天'), value: t('灵隐访古') },
      { label: t('第 3 天'), value: t('运河街巷') }
    ] },
    { title: t('资料整理'), documentTitle: t('报告 · 三点摘要'), columns: [
      { label: t('发现'), value: t('需求增长') },
      { label: t('问题'), value: t('交付偏慢') },
      { label: t('下一步'), value: t('优化流程') }
    ] }
  ];
}

// First-run shortcuts reuse the existing cloud and local provider presets.
export interface OnboardingProvider { preset: string; name: string; }

export function onboardingProviders(): OnboardingProvider[] {
  return [
    { preset: 'deepseek', name: 'DeepSeek' },
    { preset: 'zai', name: 'Z.ai' },
    { preset: 'ollama', name: 'Ollama' }
  ];
}

export function onboardingTasks(): OnboardingTask[] {
  return [
    { title: t('理清一个想法'), prompt: t('我有一个还不成熟的想法，请先问我三个问题，帮我把它变成可执行的小计划。'),
      preview: t('先聊聊目标，再把它拆成三件做得到的小事。'), icon: 'idea' },
    { title: t('读懂一份资料'), prompt: t('我想读懂一份资料。请等我添加文件，再帮我整理要点和需要核实的问题。'),
      preview: t('把长资料变短，把关键结论和疑问留下来。'), icon: 'document' },
    { title: t('把草图变成原型'), prompt: t('我想把一个草图变成可交互的原型。请先问我想解决什么问题，再等我添加草图。'),
      preview: t('从一张草图出发，一起把想象变成能点的界面。'), icon: 'sketch' }
  ];
}

// Existing chats, drafts and configured services belong to returning users.
export function isOnboardingCandidate(data: AppData): boolean {
  return !data.config.configured && !(data.providerProfiles || []).length && !(data.projects || []).length &&
    data.threads.length <= 1 && data.threads.every(thread => !thread.messages.length && !thread.draft &&
      !thread.archived && !thread.pinned && !thread.titleEdited && !thread.parentThreadId &&
      !(thread.references || []).length && !(thread.attachments || []).length && !(thread.pendingInputs || []).length);
}
