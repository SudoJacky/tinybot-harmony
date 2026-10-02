import { t } from '../../model/I18n';
import { ModelMessage, ModelTurn, ToolDefinition } from '../../model/Agent';
import { ModelConfig } from '../../model/Conversation';
import { copyProviderInfo, ProviderInfo } from '../../model/Provider';
import { Cancellation } from '../Cancellation';
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

  constructor(provider: ModelProvider, config: ModelConfig, credentials: CredentialReader) {
    this.provider = provider;
    this.credentials = credentials;
    this.baseUrl = config.baseUrl;
    this.model = config.model;
    this.alias = config.credentialAlias;
    this.reasoning = config.reasoning; this.requestUsage = config.requestUsage; this.images = config.images;
  }

  async stream(messages: ModelMessage[], tools: ToolDefinition[], cancellation: Cancellation,
    onText: (text: string) => void, options?: ModelRequestOptions): Promise<ModelTurn> {
    cancellation.check();
    if (this.images === false && messages.some((message) => (message.attachments || []).some((item) => item.mime.startsWith('image/')))) {
      throw new Error(t("当前模型设置为不支持图片，请选择视觉模型或调整能力设置。"));
    }
    // Resolve on every request, allowing later credential rotation without caching secrets.
    const key = await this.credentials.read(this.alias);
    cancellation.check();
    return this.provider.stream({ baseUrl: this.baseUrl, model: this.model, apiKey: key,
      messages: messages, tools: tools, maxOutputTokens: options?.maxOutputTokens,
      reasoning: this.reasoning, requestUsage: this.requestUsage }, cancellation, onText, options?.onReasoning);
  }
}

export class ProviderRegistry {
  private providers: Map<string, ModelProvider> = new Map<string, ModelProvider>();

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

  bind(config: ModelConfig, credentials: CredentialReader): ModelSession {
    const provider = this.require(config.providerId);
    provider.endpoint(config.baseUrl);
    if (config.model.trim().length === 0) {
      throw new Error(t("请填写模型名称。"));
    }
    // Registry edits affect future runs only; the active run keeps this provider instance.
    return new BoundModel(provider, config, credentials);
  }
}
