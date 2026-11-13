import { t } from '../../model/I18n';
import { ModelMessage, ModelTurn, ToolDefinition } from '../../model/Agent';
import { CONTENT_GUARD_REFUSAL } from '../../model/ContentGuard';
import { ModelConfig } from '../../model/Conversation';
import { copyProviderInfo, ProviderInfo } from '../../model/Provider';
import { Cancellation } from '../Cancellation';
import { ContentGuardStream } from '../ContentGuardStream';
import { OutputWordGuard, OutputWordMatcher } from '../OutputWordGuard';
import { UsageOrigin } from '../../model/Usage';
import { attachmentContext } from '../../model/AttachmentContext';
import { CredentialReader, ModelProvider, ModelRequestOptions, ModelSession } from './Provider';

class BoundModel implements ModelSession {
  private provider: ModelProvider;
  private credentials: CredentialReader;
  private baseUrl: string;
  private model: string;
  private alias: string;
  private reasoning?: string;
  private requestUsage?: boolean;
  private images?: boolean;
  private origin?: UsageOrigin;
  private authorize?: () => Promise<void>;
  private outputWords?: () => Promise<OutputWordMatcher>;

  constructor(provider: ModelProvider, config: ModelConfig, credentials: CredentialReader, origin?: UsageOrigin,
    authorize?: () => Promise<void>, outputWords?: () => Promise<OutputWordMatcher>) {
    this.provider = provider;
    this.credentials = credentials;
    this.authorize = authorize;
    this.outputWords = outputWords;
    this.origin = origin ? JSON.parse(JSON.stringify(origin)) as UsageOrigin : undefined;
    this.baseUrl = config.baseUrl;
    this.model = config.model;
    this.alias = config.credentialAlias;
    this.reasoning = config.reasoning; this.requestUsage = config.requestUsage; this.images = config.images;
  }

  async stream(messages: ModelMessage[], tools: ToolDefinition[], cancellation: Cancellation,
    onText: (text: string) => void, options?: ModelRequestOptions): Promise<ModelTurn> {
    cancellation.check();
    if (this.images === false) {
      messages = messages.map((message): ModelMessage => message.previewScreenshot ? {
        role: message.role, content: message.content + '\nThe current model is configured without image support; the screenshot was not sent. Do not claim to have visually inspected it.'
      } : message);
    }
    if (tools.some((tool) => tool.function.name === 'image_gen')) {
      messages = messages.map((message): ModelMessage => {
        if (message.previewScreenshot) { return message; }
        const photos = (message.attachments || []).filter((item) => !item.original && item.mime === 'image/jpeg');
        if (!photos.length) { return message; }
        const copy = JSON.parse(JSON.stringify(message)) as ModelMessage;
        copy.content += photos.map(attachmentContext).join('');
        if (this.images === false) {
          copy.attachments = message.attachments?.filter((item) => !photos.includes(item));
          copy.content += '\nThe current chat model cannot see these photos.';
        }
        return copy;
      });
    }
    if (this.images === false && messages.some((message) => (message.attachments || []).some((item) => item.mime.startsWith('image/')))) {
      throw new Error(t("当前模型设置为不支持图片，请选择视觉模型或调整能力设置。"));
    }
    // Resolve on every request, allowing later credential rotation without caching secrets.
    const key = await this.credentials.read(this.alias);
    await this.authorize?.();
    const matcher = await this.outputWords?.();
    cancellation.check();
    const origin: UsageOrigin = this.origin ? JSON.parse(JSON.stringify(this.origin)) as UsageOrigin : {};
    if (options?.usagePurpose) { origin.purpose = options.usagePurpose; }
    if (options?.usageStep !== undefined) { origin.step = options.usageStep; }
    const answer = matcher ? new OutputWordGuard(matcher, 'answer', onText) : undefined;
    const onReasoning = options?.onReasoning;
    const reasoning = matcher && onReasoning ? new OutputWordGuard(matcher, 'reasoning', onReasoning) : undefined;
    const guard = new ContentGuardStream(answer ? (text) => answer.push(text) : onText,
      reasoning ? (text) => reasoning.push(text) : onReasoning);
    const response = await this.provider.stream({ baseUrl: this.baseUrl, model: this.model, apiKey: key,
      usageOrigin: origin,
      messages: messages, tools: tools, maxOutputTokens: options?.maxOutputTokens,
      reasoning: this.reasoning, requestUsage: this.requestUsage }, cancellation,
      (text) => guard.pushText(text), (text) => guard.pushReasoning(text));
    cancellation.check();
    if (guard.finish(response.content)) {
      if (origin.purpose === 'title' || origin.purpose === 'compaction') {
        throw new Error(t('本次回复未通过内容审核，请调整问题后重试。'));
      }
      onText(CONTENT_GUARD_REFUSAL);
      return { content: CONTENT_GUARD_REFUSAL, toolCalls: [], usage: response.usage };
    }
    answer?.finish(response.content);
    reasoning?.finish(response.reasoningContent || '');
    return response;
  }
}

export class ProviderRegistry {
  private providers: Map<string, ModelProvider> = new Map<string, ModelProvider>();
  private authorize?: () => Promise<void>;
  private outputWords?: () => Promise<OutputWordMatcher>;

  constructor(authorize?: () => Promise<void>, outputWords?: () => Promise<OutputWordMatcher>) {
    this.authorize = authorize;
    this.outputWords = outputWords;
  }

  register(provider: ModelProvider): void {
    const info = provider.info;
    if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(info.id) || info.name.trim().length === 0) {
      throw new Error(t("Provider 注册信息无效。"));
    }
    if (this.providers.has(info.id)) {
      throw new Error(t("Provider 已注册：") + info.id);
    }
    this.providers.set(info.id, provider);
  }

  unregister(id: string): void {
    this.providers.delete(id);
  }

  list(): ProviderInfo[] {
    return Array.from(this.providers.values()).map((provider: ModelProvider): ProviderInfo => {
      return copyProviderInfo(provider.info);
    });
  }

  require(id: string): ModelProvider {
    const provider = this.providers.get(id);
    if (!provider) {
      throw new Error(t("未注册的模型服务：") + id + t("。请在模型设置中重新选择。"));
    }
    return provider;
  }

  sameCredentialScope(previous: ModelConfig, providerId: string, baseUrl: string): boolean {
    if (previous.providerId !== providerId) {
      return false;
    }
    const provider = this.require(providerId);
    return provider.endpoint(previous.baseUrl) === provider.endpoint(baseUrl);
  }

  bind(config: ModelConfig, credentials: CredentialReader, origin?: UsageOrigin): ModelSession {
    const provider = this.require(config.providerId);
    provider.endpoint(config.baseUrl);
    if (config.model.trim().length === 0) {
      throw new Error(t("请填写模型名称。"));
    }
    // Registry edits affect future runs only; the active run keeps this provider instance.
    return new BoundModel(provider, config, credentials, origin, this.authorize, this.outputWords);
  }
}
