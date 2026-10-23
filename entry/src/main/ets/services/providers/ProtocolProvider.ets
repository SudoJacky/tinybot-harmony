import { Diagnostics } from '../../model/Diagnostics';
import { t } from '../../model/I18n';
import { applyReasoningEffort } from './ReasoningRequest';
import { UsageStream, RequestUsage } from '../../model/Usage';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ModelTurn } from '../../model/Agent';
import { copyProviderInfo, ProviderInfo } from '../../model/Provider';
import { Cancellation, RunCancelledError } from '../Cancellation';
import { ChatStream } from '../ChatStream';
import { ModelStream, ResponsesStream, AnthropicStream } from './EventStreams';
import { GeminiStream } from './GeminiStream';
import { geminiRequest, geminiStreamUrl } from './GeminiProtocol';
import { protocolUrl, protocolHeaders, responsesRequest, anthropicRequest, ResponsesRequest } from './WireProtocols';
import { ModelProvider, ProviderRequest, ProviderEffects } from './Provider';
import { ChatCompletionsOptions, chatRequest, ChatRequest } from './ChatCompletionsProtocol';
import { ContextOverflowError, TransientProviderError, httpProviderError } from './ProviderErrors';

// Tinybot desktop separates request startup and stream idleness (both 120 s).
const STREAM_IDLE_TIMEOUT_MS: number = 120000;

export class ProtocolProvider implements ModelProvider {
  readonly info: ProviderInfo;
  private options: ChatCompletionsOptions;
  private effects: ProviderEffects;

  constructor(info: ProviderInfo, effects: ProviderEffects, options: ChatCompletionsOptions = {}) {
    this.info = copyProviderInfo(info);
    this.effects = effects;
    this.options = { allowHttp: options.allowHttp, replayReasoning: options.replayReasoning };
  }

  endpoint(baseUrl: string): string {
    return protocolUrl(this.info.protocol, baseUrl, this.options.allowHttp === true);
  }

  async stream(input: ProviderRequest, cancellation: Cancellation,
    onText: (text: string) => void, onReasoning?: (text: string) => void): Promise<ModelTurn> {
    cancellation.check();
    const root = this.endpoint(input.baseUrl);
    const endpoint = this.info.protocol === 'gemini' ? geminiStreamUrl(root, input.model) : root;
    const messages = await this.effects.hydrate(input.messages);
    cancellation.check();
    const usage = new UsageStream(); let firstToken: number | undefined = undefined;
    const diagnosticId = Diagnostics.nextId(); const networkMark = Diagnostics.begin(diagnosticId); let textChunks = 0; let textChars = 0;
    const receiveText = (text: string): void => {
      if (text && firstToken === undefined) { firstToken = Date.now(); if (Diagnostics.recording && networkMark) { Diagnostics.measure('network.firstText', Diagnostics.now() - networkMark.time); Diagnostics.event('network.firstText', {}, diagnosticId); } }
      textChunks++; textChars += text.length; const mark = Diagnostics.begin(diagnosticId); onText(text);
      if (Diagnostics.recording) { Diagnostics.end('network.publishText', mark, { chars: text.length, cumulativeChars: textChars, chunk: textChunks }); }
    };
    const receiveReasoning = (text: string): void => {
      const mark = Diagnostics.begin(diagnosticId); onReasoning?.(text);
      if (Diagnostics.recording) { Diagnostics.end('network.publishReasoning', mark, { chars: text.length }); }
    };
    const decoder = new util.TextDecoder('utf-8');
    const parser: ModelStream = this.info.protocol === 'responses' ? new ResponsesStream(receiveText, receiveReasoning) :
      this.info.protocol === 'gemini' ? new GeminiStream(receiveText, receiveReasoning) :
      this.info.protocol === 'anthropic-messages' ? new AnthropicStream(receiveText, receiveReasoning) : new ChatStream(receiveText, receiveReasoning);
    const body: Object = this.info.protocol === 'responses' ? responsesRequest(input.model, messages, input.tools, input.maxOutputTokens) :
      this.info.protocol === 'gemini' ? geminiRequest(messages, input.tools, input.maxOutputTokens) :
      this.info.protocol === 'anthropic-messages' ? anthropicRequest(input.model, messages, input.tools, input.maxOutputTokens, this.info.promptCaching === true) :
      chatRequest(input.model, messages, input.tools, this.options, input.maxOutputTokens);
    if (input.requestUsage !== false && this.info.protocol === 'chat-completions') { (body as ChatRequest).stream_options = { include_usage: true }; }
    applyReasoningEffort(this.info.protocol, input.model, input.reasoning, body);
    const request = http.createHttp();
    const startedAt = Date.now();
    const usageId = util.generateRandomUUID();
    this.effects.recordUsage({ id: usageId, provider: this.info.id, model: input.model, startedAt: startedAt, durationMs: 0,
      status: 'running_or_unknown', origin: input.usageOrigin });
    if (Diagnostics.acceptsLog('info')) { Diagnostics.log('info', 'network', 'request_start', { operationId: diagnosticId, providerId: this.info.id, protocol: this.info.protocol, hasModel: input.model.length > 0, messages: input.messages.length, tools: input.tools.length }); };
    return new Promise<ModelTurn>((resolve, reject) => {
      let settled = false;
      let ended = false;
      let responseCode = 0;
      let responsePrefix = '';
      let parseError: Error | undefined = undefined;
      let receivedBytes = 0;
      let timer = -1;
      let result: ModelTurn | undefined = undefined;
      let removeCancel = (): void => {};
      const settle = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (Diagnostics.recording) { Diagnostics.end('network.request', networkMark, { bytes: receivedBytes, http: responseCode, failed: error ? 1 : 0, cancelled: cancellation.cancelled ? 1 : 0, textChunks: textChunks, textChars: textChars }); }
        clearTimeout(timer);
        removeCancel();
        request.destroy();
        const record: RequestUsage = { id: usageId, provider: this.info.id, model: input.model, origin: input.usageOrigin,
          startedAt: startedAt, durationMs: Date.now() - startedAt, firstTokenMs: firstToken === undefined ? undefined : firstToken - startedAt,
          status: error ? cancellation.cancelled ? 'cancelled' : 'failed' : 'complete', tokens: usage.result() };
        this.effects.recordUsage(record); if (result) { result.usage = record; }
        if (Diagnostics.acceptsLog('info')) { Diagnostics.log('info', 'network', 'request_end', { operationId: diagnosticId, elapsedMs: Date.now() - startedAt, bytes: receivedBytes, http: responseCode, failed: error !== undefined, cancelled: cancellation.cancelled }); };
        if (error instanceof ContextOverflowError) {
          Diagnostics.log('warn', 'network', 'context_overflow', { operationId: diagnosticId, providerId: this.info.id, http: responseCode });
        }
        if (error) {
          reject(error);
        } else if (result) {
          resolve(result);
        } else {
          reject(new Error(t("模型没有返回完整结果。")));
        }
      };
      const finish = (): void => {
        if (settled || responseCode === 0) {
          return;
        }
        if (responseCode !== 200) {
          if (!ended) { return; }
          settle(httpProviderError(responseCode, responsePrefix));
          return;
        }
        if (parseError) {
          settle(parseError);
          return;
        }
        if (!ended) {
          return;
        }
        try {
          parser.push(decoder.decodeToString(new Uint8Array(0), { stream: false }));
          result = parser.finish();
          settle();
        } catch (error) {
          settle(error as Error);
        }
      };
      const resetIdleTimer = (): void => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const message = t('模型服务连续 120 秒未返回数据，请检查网络或稍后重试。');
          Diagnostics.log('warn', 'network', 'request_failed', { operationId: diagnosticId, http: responseCode,
            elapsedMs: Date.now() - startedAt, bytes: receivedBytes, phase: receivedBytes > 0 ? 'streaming' : 'connecting', retryable: true });
          settle(new TransientProviderError(message, 'timeout') as Error);
        }, STREAM_IDLE_TIMEOUT_MS);
      };
      resetIdleTimer();
      removeCancel = cancellation.onCancel(() => settle(new RunCancelledError() as Error));
      if (settled) {
        return;
      }
      try {
        request.on('dataReceive', (data: ArrayBuffer) => {
          if (settled) {
            return;
          }
          if (data.byteLength > 0) { resetIdleTimer(); }
          if (receivedBytes === 0) {
            if (Diagnostics.recording && networkMark) { Diagnostics.measure('network.firstData', Diagnostics.now() - networkMark.time); Diagnostics.event('network.firstData', {}, diagnosticId); }
            if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'network', 'first_data', { operationId: diagnosticId, elapsedMs: Date.now() - startedAt }); };
          }
          // Count bytes for diagnostics only. SSE metadata and heartbeats are not
          // retained model output; a cumulative wire-size cap cuts off valid thinking.
          // Parsers still bound individual frames, reasoning and tool arguments.
          receivedBytes += data.byteLength;
          const parseMark = Diagnostics.begin(diagnosticId);
          try {
            const text = decoder.decodeToString(new Uint8Array(data), { stream: true });
            responsePrefix += text.slice(0, Math.max(0, 16384 - responsePrefix.length));
            if (!parseError && (responseCode === 0 || responseCode === 200)) { usage.push(text); parser.push(text); }
          } catch (error) {
            parseError = error as Error;
            finish();
          } finally { if (Diagnostics.recording) { Diagnostics.end('network.decodeParse', parseMark, { bytes: data.byteLength }); } }
        });
        request.on('dataEnd', () => {
          ended = true;
          finish();
        });
        const headers = protocolHeaders(this.info.protocol, input.apiKey);
        request.requestInStream(endpoint, {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: JSON.stringify(body),
          usingCache: false,
          connectTimeout: 15000,
          // SDK 0 disables its deadline; the resettable idle timer above owns reads.
          readTimeout: 0
        }, (error: BusinessError, code: number) => {
          if (error) {
            const retryable = [2300005, 2300006, 2300007, 2300028, 2300052, 2300056].includes(error.code);
            Diagnostics.log('error', 'network', 'request_failed', { operationId: diagnosticId, code: error.code, http: responseCode,
              elapsedMs: Date.now() - startedAt, bytes: receivedBytes, phase: receivedBytes > 0 ? 'streaming' : 'connecting', retryable: retryable }, error);
            const message = t("网络请求失败（{0}），请检查连接和服务地址。", [error.code]);
            // The loop retries only an uncommitted model request, with fresh parsers.
            settle(retryable ? new TransientProviderError(message, 'transport') : new Error(message));
            return;
          }
          responseCode = code;
          finish();
        });
      } catch (_) {
        settle(new Error(t("无法创建网络请求，请检查模型配置。")));
      }
    });
  }
}
