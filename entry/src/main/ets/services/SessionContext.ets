import { INTERACTIVE_UI_INSTRUCTIONS } from '../model/InteractiveUiInstructions';
import { MAX_AGENT_STEPS, ModelMessage, ToolDefinition } from '../model/Agent';
import { ModelConfig, ThreadData } from '../model/Conversation';
import { ExtensionSettings, skillCatalog } from '../model/Skills';
import { Cancellation } from './Cancellation';
import { ModelSession } from './providers/Provider';
import { DEFAULT_SYSTEM_PROMPT, runtimeInstructions, userDocumentContext } from '../model/SystemPrompt';
import { PromptSection, renderPrompt, threadEntries } from '../model/ContextProjection';
import { ContextSource, RequestContext } from './RequestContext';

export function sessionInstructions(config: ModelConfig, extensions: ExtensionSettings, selected: string = ''): string {
  return renderPrompt(sessionPromptSections(config, extensions, selected));
}

export function sessionPromptSections(config: ModelConfig, extensions: ExtensionSettings, selected: string = ''): PromptSection[] {
  return [{ name: 'identity', content: DEFAULT_SYSTEM_PROMPT },
    { name: 'runtime', content: runtimeInstructions(MAX_AGENT_STEPS) },
    { name: 'interactive_ui', content: INTERACTIVE_UI_INSTRUCTIONS },
    { name: 'user_preferences', content: userDocumentContext(config.userDocument || '') },
    { name: 'skills', content: skillCatalog(extensions.skills, selected) }];
}

export function sessionContextSource(thread: ThreadData, sections: () => PromptSection[], persist: () => Promise<void>,
  progress: (status: string) => void): ContextSource {
  return { state: thread, entries: () => threadEntries(thread), sections: sections, persist: persist, progress: progress };
}

// The caller owns the thread and commit boundary; this module owns budgeting and compaction policy.
export async function prepareSessionContext(thread: ThreadData, model: ModelSession, cancellation: Cancellation,
  manual: boolean, config: ModelConfig, instructions: string, tools: ToolDefinition[],
  persist: () => Promise<void>, progress: (status: string) => void): Promise<ModelMessage[]> {
  const context = new RequestContext(sessionContextSource(thread, () => [{ name: 'instructions', content: instructions }], persist, progress), config);
  return (await context.prepare(model, tools, cancellation, [], manual)).messages;
}
