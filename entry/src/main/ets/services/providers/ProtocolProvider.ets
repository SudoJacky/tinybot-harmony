import { t } from '../../model/I18n';
import { applyReasoningEffort } from './ReasoningRequest';
import { Attachments } from '../Attachments';
import { UsageStream, RequestUsage } from '../../model/Usage';
import { UsageLedger } from '../UsageLedger';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ModelTurn } from '../../model/Agent';
import { copyProviderInfo, ProviderInfo } from '../../model/Provider';
import { Cancellation, RunCancelledError } from '../Cancellation';
import { ChatStream } from '../ChatStream';
import { ModelStream, ResponsesStream, AnthropicStream } from './EventStreams';
import { protocolUrl, protocolHeaders, responsesRequest, anthropicRequest, ResponsesRequest } from './WireProtocols';
import { ModelProvider, ProviderRequest } from './Provider';
import { ChatCompletionsOptions, chatRequest, ChatRequest } from './ChatCompletionsProtocol';

// Tinybot desktop separates request startup and stream idleness (both 120 s).
const STREAM_IDLE_TIMEOUT_MS: number = 120000;

export class ProtocolProvider implements ModelProvider {
  readonly info: ProviderInfo;
  private options: ChatCompletionsOptions;

  constructor(info: ProviderInfo, options: ChatCompletionsOptions = {}) {
    this.info = copyProviderInfo(info);
    this.options = { allowHttp: options.allowHttp, replayReasoning: options.replayReasoning };
  }

  endpoint(baseUrl: string): string {
    return protocolUrl(this.info.protocol, baseUrl, this.options.allowHttp === true);
  }

  async stream(input: ProviderRequest, cancellation: Cancellation,
    onText: (text: string) => void, onReasoning?: (text: string) => void): Promise<ModelTurn> {
    cancellation.check();
    const endpoint = this.endpoint(input.baseUrl);
    const messages = await Attachments.hydrate(input.messages);
    cancellation.check();
    const usage = new UsageStream(); let firstToken: number | undefined = undefined;
    const receiveText = (text: string): void => { if (text && firstToken === undefined) { firstToken = Date.now(); } onText(text); };
    const decoder = new util.TextDecoder('utf-8');
    const parser: ModelStream = this.info.protocol === 'responses' ? new ResponsesStream(receiveText, onReasoning) :
      this.info.protocol === 'anthropic-messages' ? new AnthropicStream(receiveText, onReasoning) : new ChatStream(receiveText, onReasoning);
    const body: Object = this.info.protocol === 'responses' ? responsesRequest(input.model, messages, input.tools, input.maxOutputTokens) :
      this.info.protocol === 'anthropic-messages' ? anthropicRequest(input.model, messages, input.tools, input.maxOutputTokens) :
      chatRequest(input.model, messages, input.tools, this.options, input.maxOutputTokens);
    if (input.requestUsage !== false && this.info.protocol === 'chat-completions') { (body as ChatRequest).stream_options = { include_usage: true }; }
    applyReasoningEffort(this.info.protocol, input.model, input.reasoning, body);
    const request = http.createHttp();
    const startedAt = Date.now();
    const usageId = util.generateRandomUUID();
    UsageLedger.record({ id: usageId, provider: this.info.id, model: input.model, startedAt: startedAt, durationMs: 0,
      status: 'running_or_unknown', origin: input.usageOrigin });
    hilog.info(0x0000, 'TinybotNetwork', 'Request start provider=%{public}s protocol=%{public}s model=%{public}s messages=%{public}d tools=%{public}d',
      this.info.id, this.info.protocol, input.model, input.messages.length, input.tools.length);
    return new Promise<ModelTurn>((resolve, reject) => {
      let settled = false;
      let ended = false;
      let responseCode = 0;
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
        clearTimeout(timer);
        removeCancel();
        request.destroy();
        const record: RequestUsage = { id: usageId, provider: this.info.id, model: input.model, origin: input.usageOrigin,
          startedAt: startedAt, durationMs: Date.now() - startedAt, firstTokenMs: firstToken === undefined ? undefined : firstToken - startedAt,
          status: error ? cancellation.cancelled ? 'cancelled' : 'failed' : 'complete', tokens: usage.result() };
        UsageLedger.record(record); if (result) { result.usage = record; }
        hilog.info(0x0000, 'TinybotNetwork', 'Request ended elapsedMs=%{public}d bytes=%{public}d http=%{public}d failed=%{public}s',
          Date.now() - startedAt, receivedBytes, responseCode, (error !== undefined).toString());
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
          settle(new Error(t("模型服务返回 HTTP {0}，请检查地址、API Key、模型名称和额度。", [responseCode])));
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
        timer = setTimeout(() => settle(new Error(t('模型服务连续 120 秒未返回数据，请检查网络或稍后重试。'))), STREAM_IDLE_TIMEOUT_MS);
      };
      resetIdleTimer();
      removeCancel = cancellation.onCancel(() => settle(new RunCancelledError() as Error));
      if (settled) {
        return;
      }
      try {
        request.on('dataReceive', (data: ArrayBuffer) => {
          if (settled || parseError) {
            return;
          }
          if (data.byteLength > 0) { resetIdleTimer(); }
          if (receivedBytes === 0) {
            hilog.info(0x0000, 'TinybotNetwork', 'First data elapsedMs=%{public}d', Date.now() - startedAt);
          }
          // Count bytes for diagnostics only. SSE metadata and heartbeats are not
          // retained model output; a cumulative wire-size cap cuts off valid thinking.
          // Parsers still bound individual frames, reasoning and tool arguments.
          receivedBytes += data.byteLength;
          try {
            const text = decoder.decodeToString(new Uint8Array(data), { stream: true }); usage.push(text); parser.push(text);
          } catch (error) {
            parseError = error as Error;
            finish();
          }
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
            hilog.error(0x0000, 'TinybotNetwork', 'Request error code=%{public}d elapsedMs=%{public}d bytes=%{public}d',
              error.code, Date.now() - startedAt, receivedBytes);
            settle(new Error(t("网络请求失败（{0}），请检查连接和服务地址。", [error.code])));
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
