import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ModelTurn } from '../../model/Agent';
import { copyProviderInfo, ProviderInfo } from '../../model/Provider';
import { Cancellation, RunCancelledError } from '../Cancellation';
import { ChatStream } from '../ChatStream';
import { ModelProvider, ProviderRequest } from './Provider';
import { ChatCompletionsOptions, chatRequest, completionUrl } from './ChatCompletionsProtocol';

export class ChatCompletionsProvider implements ModelProvider {
  readonly info: ProviderInfo;
  private options: ChatCompletionsOptions;

  constructor(info: ProviderInfo, options: ChatCompletionsOptions = {}) {
    this.info = copyProviderInfo(info);
    this.options = { allowHttp: options.allowHttp, replayReasoning: options.replayReasoning };
  }

  endpoint(baseUrl: string): string {
    return completionUrl(baseUrl, this.options.allowHttp === true);
  }

  async stream(input: ProviderRequest, cancellation: Cancellation,
    onText: (text: string) => void): Promise<ModelTurn> {
    cancellation.check();
    const endpoint = this.endpoint(input.baseUrl);
    const request = http.createHttp();
    const decoder = new util.TextDecoder('utf-8');
    const parser = new ChatStream(onText);
    const body = chatRequest(input.model, input.messages, input.tools, this.options);
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
        const headers: Record<string, string> = {
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream'
        };
        if (input.apiKey.length > 0) {
          headers['Authorization'] = 'Bearer ' + input.apiKey;
        }
        request.requestInStream(endpoint, {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: JSON.stringify(body),
          usingCache: false,
          connectTimeout: 15000,
          readTimeout: 60000
        }, (error: BusinessError, code: number) => {
          if (error) {
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
