import { ModelMessage, ModelTurn, ToolDefinition } from '../../model/Agent';
import { ProviderInfo } from '../../model/Provider';
import { Cancellation } from '../Cancellation';
import { UsageOrigin } from '../../model/Usage';

export interface CredentialReader {
  read(alias: string): Promise<string>;
}

export interface ProviderRequest {
  usageOrigin?: UsageOrigin;
  reasoning?: string;
  requestUsage?: boolean;
  baseUrl: string;
  model: string;
  apiKey: string;
  messages: ModelMessage[];
  tools: ToolDefinition[];
  maxOutputTokens?: number;
}

export interface ModelRequestOptions {
  usagePurpose?: string;
  usageStep?: number;
  maxOutputTokens?: number;
  onReasoning?: (text: string) => void;
}

// Providers own endpoint rules and protocol encoding; each request owns its transport.
export interface ModelProvider {
  readonly info: ProviderInfo;
  endpoint(baseUrl: string): string;
  stream(request: ProviderRequest, cancellation: Cancellation,
    onText: (text: string) => void, onReasoning?: (text: string) => void): Promise<ModelTurn>;
}

// A provider/model/configuration snapshot bound for one Agent run. No credentials in events.
export interface ModelSession {
  stream(messages: ModelMessage[], tools: ToolDefinition[], cancellation: Cancellation,
    onText: (text: string) => void, options?: ModelRequestOptions): Promise<ModelTurn>;
}
