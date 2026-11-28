import { AppData } from './Conversation';

export const ONBOARDING_STEP_KEY: string = 'onboardingStep';

// Existing chats, drafts and configured services belong to returning users.
export function isOnboardingCandidate(data: AppData): boolean {
  return !data.config.configured && !(data.providerProfiles || []).length && !(data.projects || []).length &&
    data.threads.length <= 1 && data.threads.every(thread => !thread.messages.length && !thread.draft &&
      !thread.archived && !thread.pinned && !thread.titleEdited && !thread.parentThreadId &&
      !(thread.references || []).length && !(thread.attachments || []).length && !(thread.pendingInputs || []).length);
}

export interface FirstUseStatus { onboarding: boolean; backup: boolean; }

export function firstUseStatus(data: AppData): FirstUseStatus {
  const onboarding = isOnboardingCandidate(data);
  return { onboarding: onboarding, backup: onboarding && !(data.config.userDocument || '').trim() &&
    !(data.productivity?.servers || []).length && !(data.productivity?.memories || []).length };
}
