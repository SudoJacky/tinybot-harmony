import { AgentStep, ModelMessage, interruptTools, stepMessages, validateSteps } from './Agent';
import { builtinProviderInfos, DEFAULT_PROVIDER_ID, LEGACY_PROVIDER_ID } from './Provider';
import { contextSettings, validateCompaction } from './ConversationContext';
import { ModelReference, ProviderProfile, validateProfile, validateReference } from './ProviderProfiles';
import { ExtensionSettings, validateExtensions } from './Skills';
import { PendingInput, validatePendingInputs } from './PendingInput';

const LEGACY_SYSTEM_PROMPT: string = '你是 Tinybot，一个运行在 HarmonyOS 手机上的个人 AI 助手。请用清晰、自然的语言帮助用户。你目前只能对话，不能访问手机文件、执行命令或操作其他应用。不要声称执行了未提供的工具。';
const DEFAULT_SYSTEM_PROMPT: string = '你是 Tinybot，一个运行在 HarmonyOS 手机上的个人 AI 助手。请用清晰、自然的语言帮助用户，并使用提供的工具完成任务。不要声称执行了未提供的工具。';

export interface ModelConfig {
  configured: boolean;
  providerId: string;
  baseUrl: string;
  model: string;
  systemPrompt: string;
  credentialAlias: string;
  contextWindow?: number;
  autoCompact?: boolean;
}

export interface MessageData {
  id: string;
  role: string;
  content: string;
  status: string;
  error: string;
  steps?: AgentStep[];
  modelRef?: ModelReference;
}

export interface CompactionData {
  summary: string;
  firstKeptMessageId: string;
  tokensBefore: number;
  createdAt: number;
}

export function copyModelConfig(config: ModelConfig, configured: boolean = config.configured): ModelConfig {
  return { configured: configured, providerId: config.providerId, baseUrl: config.baseUrl, model: config.model,
    systemPrompt: config.systemPrompt, credentialAlias: config.credentialAlias,
    contextWindow: config.contextWindow, autoCompact: config.autoCompact };
}

export interface ThreadData {
  id: string;
  title: string;
  updatedAt: number;
  messages: MessageData[];
  pinned?: boolean;
  archived?: boolean;
  titleEdited?: boolean;
  draft?: string;
  compaction?: CompactionData;
  modelRef?: ModelReference;
  pendingInputs?: PendingInput[];
  queuePaused?: boolean;
}

export interface AppData {
  version: number;
  config: ModelConfig;
  threads: ThreadData[];
  activeThreadId: string;
  providerProfiles?: ProviderProfile[];
  extensions?: ExtensionSettings;
}

export function defaultConfig(): ModelConfig {
  const provider = builtinProviderInfos()[0];
  return {
    configured: false,
    providerId: DEFAULT_PROVIDER_ID,
    baseUrl: provider.defaultBaseUrl,
    model: provider.defaultModel,
    systemPrompt: DEFAULT_SYSTEM_PROMPT,
    credentialAlias: '', contextWindow: 32768, autoCompact: true
  };
}

export function emptyData(): AppData {
  return { version: 1, config: defaultConfig(), threads: [], activeThreadId: '' };
}

// Replay completed text and tool receipts. Interrupted prose is excluded, but file effects remain known.
export function requestHistory(messages: MessageData[], systemPrompt: string): ModelMessage[] {
  const result: ModelMessage[] = [];
  if (systemPrompt.trim().length > 0) {
    result.push({ role: 'system', content: systemPrompt });
  }
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index];
    if (message.role !== 'user') {
      continue;
    }
    const answer = messages[index + 1];
    if (!answer) {
      result.push({ role: 'user', content: message.content });
    } else if (answer.role === 'assistant') {
      const steps = answer.steps || [];
      const hasTools = steps.some((step: AgentStep) => step.tools.length > 0);
      const hasSteering = steps.some((step: AgentStep) => step.steering !== undefined);
      if (answer.status !== 'complete' && !hasTools && !hasSteering) {
        continue;
      }
      result.push({ role: 'user', content: message.content });
      if (steps.length === 0) {
        result.push({ role: 'assistant', content: answer.content });
      } else {
        for (const step of steps) {
          if (step.tools.length > 0 || (answer.status === 'complete' && step.content.length > 0)) {
            result.push(...stepMessages(step));
          } else if (step.steering) {
            result.push({ role: 'user', content: step.steering.text });
          }
        }
        if (answer.status !== 'complete') {
          result.push({ role: 'assistant', content: '上轮执行已中断。已接收的追加指令和以上工具结果仍保留；不要假设文件操作已经回滚。' });
        }
      }
    }
  }
  return result;
}

export function parseAppData(text: string): AppData {
  const data = JSON.parse(text) as AppData;
  if (!data || data.version !== 1 || !data.config || !Array.isArray(data.threads) ||
    typeof data.activeThreadId !== 'string' || typeof data.config.configured !== 'boolean' || typeof data.config.baseUrl !== 'string' ||
    typeof data.config.model !== 'string' || typeof data.config.systemPrompt !== 'string' ||
    typeof data.config.credentialAlias !== 'string') {
    throw new Error('本地数据格式不受支持，原文件已保留。');
  }
  const threadIds = new Set<string>();
  if (data.extensions !== undefined) { validateExtensions(data.extensions); }
  contextSettings(data.config);
  if (data.providerProfiles !== undefined) {
    if (!Array.isArray(data.providerProfiles)) { throw new Error('模型服务列表损坏。'); }
    const ids = new Set<string>();
    const aliases = new Set<string>();
    for (const profile of data.providerProfiles) {
      validateProfile(profile);
      if (ids.has(profile.id) || (profile.credentialAlias.length > 0 && aliases.has(profile.credentialAlias))) {
        throw new Error('模型服务 ID 或密钥别名重复。');
      }
      ids.add(profile.id);
      if (profile.credentialAlias.length > 0) { aliases.add(profile.credentialAlias); }
    }
  }
  if (data.config.providerId === undefined) {
    // Every existing endpoint used this protocol. Preserve arbitrary user endpoints and keys.
    data.config.providerId = LEGACY_PROVIDER_ID;
  } else if (typeof data.config.providerId !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(data.config.providerId)) {
    throw new Error('本地模型服务配置损坏，原文件已保留。');
  }
  if (data.config.systemPrompt === LEGACY_SYSTEM_PROMPT) {
    data.config.systemPrompt = DEFAULT_SYSTEM_PROMPT;
  }
  for (const thread of data.threads) {
    if (!thread || typeof thread.id !== 'string' || thread.id.length === 0 || threadIds.has(thread.id) ||
      typeof thread.title !== 'string' || typeof thread.updatedAt !== 'number' ||
      !Number.isFinite(thread.updatedAt) || !Array.isArray(thread.messages) || thread.messages.length % 2 !== 0) {
      throw new Error('本地会话数据损坏，原文件已保留。');
    }
    threadIds.add(thread.id);
    if (thread.pendingInputs !== undefined) { validatePendingInputs(thread.pendingInputs); }
    if (thread.queuePaused !== undefined && typeof thread.queuePaused !== 'boolean') { throw new Error('本地队列状态损坏。'); }
    // Loading never authorizes autonomous execution after a process exit.
    if ((thread.pendingInputs || []).length > 0) { thread.queuePaused = true; }
    if (thread.modelRef !== undefined) { validateReference(thread.modelRef); }
    if ((thread.pinned !== undefined && typeof thread.pinned !== 'boolean') ||
      (thread.archived !== undefined && typeof thread.archived !== 'boolean') ||
      (thread.titleEdited !== undefined && typeof thread.titleEdited !== 'boolean') ||
      (thread.draft !== undefined && (typeof thread.draft !== 'string' || thread.draft.length > 24000))) {
      throw new Error('本地会话管理数据损坏，原文件已保留。');
    }
    const messageIds = new Set<string>();
    for (let index = 0; index < thread.messages.length; index++) {
      const message = thread.messages[index];
      if (!message || typeof message.id !== 'string' || message.id.length === 0 || messageIds.has(message.id) ||
        message.role !== (index % 2 === 0 ? 'user' : 'assistant') ||
        (message.role === 'user' && message.status !== 'complete') ||
        typeof message.content !== 'string' || typeof message.error !== 'string' ||
        ['complete', 'generating', 'stopped', 'failed'].indexOf(message.status) < 0) {
        throw new Error('本地消息数据损坏，原文件已保留。');
      }
      messageIds.add(message.id);
      if (message.modelRef !== undefined) { validateReference(message.modelRef); }
      if (message.steps !== undefined) {
        validateSteps(message.steps);
        if (message.role !== 'assistant' && message.steps.length > 0) {
          throw new Error('本地工具记录损坏，原文件已保留。');
        }
        interruptTools(message.steps);
        for (const step of message.steps) {
          if (step.steering && (thread.pendingInputs || []).some((input: PendingInput) => input.id === step.steering?.id)) {
            throw new Error('追加指令同时出现在历史和待发送队列中。');
          }
        }
      }
      if (message.status === 'generating') {
        message.status = 'stopped';
        message.error = '应用退出时执行尚未完成。已完成的文件操作会保留；可继续发送指令。';
      }
    }
    if (thread.compaction !== undefined) { validateCompaction(thread.compaction, thread); }
  }
  if (data.activeThreadId.length > 0 && !threadIds.has(data.activeThreadId)) {
    throw new Error('找不到上次打开的会话，原文件已保留。');
  }
  return data;
}
