import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ModelTurn } from '../../model/Agent';
import { copyProviderInfo, ProviderInfo } from '../../model/Provider';
import { Cancellation, RunCancelledError } from '../Cancellation';
import { ChatStream } from '../ChatStream';
import { ModelStream, ResponsesStream, AnthropicStream } from './EventStreams';
import { protocolUrl, protocolHeaders, responsesRequest, anthropicRequest } from './WireProtocols';
import { ModelProvider, ProviderRequest } from './Provider';
import { ChatCompletionsOptions, chatRequest } from './ChatCompletionsProtocol';

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
    onText: (text: string) => void): Promise<ModelTurn> {
    cancellation.check();
    const endpoint = this.endpoint(input.baseUrl);
    const request = http.createHttp();
    const decoder = new util.TextDecoder('utf-8');
    const parser: ModelStream = this.info.protocol === 'responses' ? new ResponsesStream(onText) :
      this.info.protocol === 'anthropic-messages' ? new AnthropicStream(onText) : new ChatStream(onText);
    const body: Object = this.info.protocol === 'responses' ? responsesRequest(input.model, input.messages, input.tools, input.maxOutputTokens) :
      this.info.protocol === 'anthropic-messages' ? anthropicRequest(input.model, input.messages, input.tools, input.maxOutputTokens) :
      chatRequest(input.model, input.messages, input.tools, this.options, input.maxOutputTokens);
    const startedAt = Date.now();
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
        hilog.info(0x0000, 'TinybotNetwork', 'Request ended elapsedMs=%{public}d bytes=%{public}d http=%{public}d failed=%{public}s',
          Date.now() - startedAt, receivedBytes, responseCode, (error !== undefined).toString());
        if (error) {
          reject(error);
        } else if (result) {
          resolve(result);
        } else {
          reject(new Error('模型没有返回完整结果。'));
        }
      };
      const finish = (): void => {
        if (settled || responseCode === 0) {
          return;
        }
        if (responseCode !== 200) {
          settle(new Error(`模型服务返回 HTTP ${responseCode}，请检查地址、API Key、模型名称和额度。`));
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
      timer = setTimeout(() => settle(new Error('本次请求超过 3 分钟，请检查网络或稍后重试。')), 180000);
      removeCancel = cancellation.onCancel(() => settle(new RunCancelledError() as Error));
      if (settled) {
        return;
      }
      try {
        request.on('dataReceive', (data: ArrayBuffer) => {
          if (settled || parseError) {
            return;
          }
          if (receivedBytes === 0) {
            hilog.info(0x0000, 'TinybotNetwork', 'First data elapsedMs=%{public}d', Date.now() - startedAt);
          }
          receivedBytes += data.byteLength;
          if (receivedBytes > 2 * 1024 * 1024) {
            settle(new Error('单次回答超过 2 MB，请缩小问题范围。'));
            return;
          }
          try {
            parser.push(decoder.decodeToString(new Uint8Array(data), { stream: true }));
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
          readTimeout: 60000
        }, (error: BusinessError, code: number) => {
          if (error) {
            hilog.error(0x0000, 'TinybotNetwork', 'Request error code=%{public}d elapsedMs=%{public}d bytes=%{public}d',
              error.code, Date.now() - startedAt, receivedBytes);
            settle(new Error(`网络请求失败（${error.code}），请检查连接和服务地址。`));
            return;
          }
          responseCode = code;
          finish();
        });
      } catch (_) {
        settle(new Error('无法创建网络请求，请检查模型配置。'));
      }
    });
  }
}
