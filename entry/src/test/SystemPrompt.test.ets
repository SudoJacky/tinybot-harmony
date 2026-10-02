import { describe, expect, it } from '@ohos/hypium';
import { defaultConfig, emptyData, parseAppData } from '../main/ets/model/Conversation';
import { defaultExtensions, parseSkill } from '../main/ets/model/Skills';
import { DEFAULT_SYSTEM_PROMPT, teamWorkerInstructions } from '../main/ets/model/SystemPrompt';
import { sessionInstructions } from '../main/ets/services/SessionContext';

export default function systemPromptTests(): void {
  describe('SystemPrompt', () => {
    it('upgradesBothShippedDefaultsWhenLoadingExistingData', 0, () => {
      const oldDefaults = [
        '你是 Tinybot，一个运行在 HarmonyOS 手机上的个人 AI 助手。请用清晰、自然的语言帮助用户。你目前只能对话，不能访问手机文件、执行命令或操作其他应用。不要声称执行了未提供的工具。',
        '你是 Tinybot，一个运行在 HarmonyOS 手机上的个人 AI 助手。请用清晰、自然的语言帮助用户，并使用提供的工具完成任务。不要声称执行了未提供的工具。'
      ];
      oldDefaults.forEach((prompt: string) => {
        const data = emptyData(); data.config.systemPrompt = prompt;
        expect(parseAppData(JSON.stringify(data)).config.systemPrompt).assertEqual(DEFAULT_SYSTEM_PROMPT);
      });
      expect(defaultConfig().systemPrompt).assertEqual(DEFAULT_SYSTEM_PROMPT);
      expect(DEFAULT_SYSTEM_PROMPT.length < 4000).assertTrue();
    });
    it('preservesCustomAndEmptyPromptsAcrossReloads', 0, () => {
      ['', 'Answer in English.\nKeep my formatting.', DEFAULT_SYSTEM_PROMPT + '\n只回答一句话。'].forEach((prompt: string) => {
        const data = emptyData(); data.config.systemPrompt = prompt;
        const restored = parseAppData(JSON.stringify(data));
        expect(restored.config.systemPrompt).assertEqual(prompt);
        expect(parseAppData(JSON.stringify(restored)).config.systemPrompt).assertEqual(prompt);
      });
    });
    it('composesRuntimeAndOnlyEnabledWebAndSkillContextWithoutMutatingSettings', 0, () => {
      const config = defaultConfig(); config.systemPrompt = 'My custom assistant';
      const extensions = defaultExtensions(); extensions.webEnabled = false;
      extensions.skills = [parseSkill('---\nname: report\ndescription: Summarize reports\ndisable-model-invocation: true\n---\nRead the source.')];
      const base = sessionInstructions(config, extensions);
      expect(base.startsWith(config.systemPrompt + '\n\n<runtime>')).assertTrue();
      expect(base.includes('<web>')).assertFalse();
      expect(base.includes('Summarize reports')).assertFalse();
      expect(base.includes('<team_coordinator>')).assertFalse();
      extensions.webEnabled = true;
      const selected = sessionInstructions(config, extensions, 'report');
      expect(selected.includes('<web>')).assertTrue();
      expect(selected.includes('Summarize reports')).assertTrue();
      expect(config.systemPrompt).assertEqual('My custom assistant');
    });
    it('requiresChatHandoffOnlyForWorkersWithTheCompletionTool', 0, () => {
      expect(teamWorkerInstructions(true).includes('team_complete_task')).assertTrue();
      expect(teamWorkerInstructions(false).includes('team_complete_task')).assertFalse();
      expect(teamWorkerInstructions(true).includes('<team_coordinator>')).assertFalse();
    });
  });
}
