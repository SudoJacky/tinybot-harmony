import { AppData } from './Conversation';
import { t } from './I18n';

export interface OnboardingTask { title: string; prompt: string; preview: string; icon: string; }

export interface OnboardingExample {
  kind: 'research' | 'trip' | 'digest';
  title: string;
  description: string;
}
export interface OnboardingResearch extends OnboardingExample {
  heading: string; subject: string; traffic: number[]; hours: string[];
  peak: string; tags: string[]; suggestion: string; offer: string; source: string;
}
export interface OnboardingTrip extends OnboardingExample {
  heading: string; duration: string; weather: string; stops: string[]; footer: string;
}
export interface OnboardingDigest extends OnboardingExample {
  heading: string; compression: string; conclusions: string[]; verification: string;
}

export function onboardingIntroduction(): string[] {
  return [
    t('嗨，我是 Tiny，你的 AI 小助手。'),
    t('我能陪你做市场调研、规划旅行，也能帮你读懂资料。'),
    t('不用一次想清楚。先说个想法，我陪你把它变成下一步。')
  ];
}

export function onboardingExamples(): OnboardingExample[] {
  const research: OnboardingResearch = {
    kind: 'research', title: t('市场调研'), heading: t('调研速览'), subject: t('社区咖啡店'),
    traffic: [10, 20, 34, 27, 15, 8], hours: ['7', '8', '9', '10', '11', '12'],
    peak: t('早高峰占 62%'), tags: [t('上班族'), t('快速取餐')],
    suggestion: t('建议：早餐咖啡组合'), offer: t('¥15 咖啡＋可颂'), source: t('基于 3 份资料'),
    description: t('示例：社区咖啡店调研速览，早高峰占六成，建议主推早餐咖啡组合。')
  };
  const trip: OnboardingTrip = {
    kind: 'trip', title: t('旅行规划'), heading: t('杭州'), duration: t('三天两晚'), weather: t('晴 22°'),
    stops: [t('西湖漫步'), t('灵隐访古'), t('运河街巷')], footer: t('步行约 9km · 2 晚住宿'),
    description: t('示例：杭州三天两晚行程，西湖、灵隐与运河，步行约九公里，两晚住宿。')
  };
  const digest: OnboardingDigest = {
    kind: 'digest', title: t('资料整理'), heading: t('报告 · 三点摘要'), compression: t('42 页 → 3 点'),
    conclusions: [t('需求增长 ↑18%'), t('交付偏慢 +2 天'), t('下一步 优化排期')], verification: t('待核实'),
    description: t('示例：四十二页报告整理为三点摘要，需求增长百分之十八，交付偏慢两天待核实，下一步优化排期。')
  };
  return [research, trip, digest];
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
