import { ProviderInfo } from '../../model/Provider';
import { ChatCompletionsOptions } from './ChatCompletionsProtocol';
import { ProtocolProvider } from './ProtocolProvider';

export class ChatCompletionsProvider extends ProtocolProvider {
  constructor(info: ProviderInfo, options: ChatCompletionsOptions = {}) {
    if (info.protocol !== 'chat-completions') { throw new Error('Chat Completions 适配器不能绑定其他协议。'); }
    super(info, options);
  }
}