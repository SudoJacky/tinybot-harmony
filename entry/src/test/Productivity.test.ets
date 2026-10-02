import { describe, expect, it } from '@ohos/hypium';
import { Attachment, PromptTemplate, defaultProductivity, expandTemplate, memoryContext, validateAttachments, validateProductivity } from '../main/ets/model/Productivity';
import { markdownBlocks, markdownSpans } from '../main/ets/model/Markdown';
import { chatRequest } from '../main/ets/services/providers/ChatCompletionsProtocol';
import { responsesRequest, anthropicRequest } from '../main/ets/services/providers/WireProtocols';
import { ModelMessage } from '../main/ets/model/Agent';
import { estimateContextTokens } from '../main/ets/model/ConversationContext';
import { mcpResponse } from '../main/ets/services/McpClient';

function rejects(action: () => void): void { let rejected = false; try { action(); } catch (_) { rejected = true; } expect(rejected).assertTrue(); }

export default function productivityTests(): void {
  describe('Productivity', () => {
    it('scopesMemoriesAndValidatesBeforeSaving', 0, () => {
      const data = defaultProductivity();
      data.memories = [{ id: 'm1', content: 'global', threadId: '', updatedAt: 1 }, { id: 'm2', content: 'private', threadId: 'a', updatedAt: 2 }];
      validateProductivity(data);
      expect(memoryContext(data, 'b').includes('global')).assertTrue();
      expect(memoryContext(data, 'b').includes('private')).assertFalse();
      expect(memoryContext(data, 'a').includes('private')).assertTrue();
      data.memories[1].content = 'x'.repeat(2001); rejects(() => validateProductivity(data));
    });
    it('expandsTemplatesWithoutTreatingInputAsReplacementSyntax', 0, () => {
      const template: PromptTemplate = { id: 't', name: 't', content: '{{input}} / {{input}}' };
      expect(expandTemplate(template, '$&')).assertEqual('$& / $&');
      rejects(() => expandTemplate(template, 'a'.repeat(13000)));
    });
    it('rejectsEscapingAttachmentPathsAndUnboundedCounts', 0, () => {
      const item: Attachment = { id: 'a1', name: 'photo', mime: 'image/jpeg', path: 'a1.jpg', size: 100 };
      validateAttachments([item]);
      item.path = '../secret'; rejects(() => validateAttachments([item]));
      item.path = 'a1.jpg'; rejects(() => validateAttachments([item, item]));
    });
    it('encodesImagesForAllThreeProtocolsWithoutPersistedBase64', 0, () => {
      const messages: ModelMessage[] = [{ role: 'user', content: 'describe', images: ['data:image/jpeg;base64,YQ=='] }];
      const chat = JSON.stringify(chatRequest('vision', messages, []));
      const responses = JSON.stringify(responsesRequest('vision', messages, []));
      const anthropic = JSON.stringify(anthropicRequest('vision', messages, []));
      expect(chat.includes('image_url')).assertTrue();
      expect(responses.includes('input_image')).assertTrue();
      expect(anthropic.includes('"media_type":"image/jpeg"')).assertTrue();
      expect(anthropic.includes('"data":"YQ=="')).assertTrue();
      expect(messages[0].content).assertEqual('describe');
    });
    it('budgetsImageAndTextAttachments', 0, () => {
      const messages: ModelMessage[] = [{ role: 'user', content: 'test' }];
      const before = estimateContextTokens(messages);
      messages[0].attachments = [{ id: 'a', name: 'photo', path: 'a.jpg', mime: 'image/jpeg', size: 100 }];
      expect(estimateContextTokens(messages) - before).assertEqual(1800);
    });
    it('rendersFencesTablesAndSafeInlineLinks', 0, () => {
      const blocks = markdownBlocks('# 标题\n\n```ts\nconst x = 1;\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |');
      expect(blocks[0].kind).assertEqual('heading');
      expect(blocks[1].kind).assertEqual('code'); expect(blocks[1].text).assertEqual('const x = 1;');
      expect(blocks[2].rows[1][1]).assertEqual('2');
      expect(markdownSpans('[站点](https://example.com)')[0].url).assertEqual('https://example.com');
      expect(markdownSpans('[bad](javascript:alert)')[0].kind).assertEqual('text');
      expect(markdownBlocks('```\npartial')[0].text).assertEqual('partial');
    });
    it('matchesMcpResponseIdsInJsonAndSse', 0, () => {
      expect(mcpResponse('{"jsonrpc":"2.0","id":2,"result":{}}', 1)).assertUndefined();
      expect(mcpResponse('event: message\r\ndata: {"jsonrpc":"2.0","id":1,"result":{}}\r\n\r\n', 1)?.id).assertEqual(1);
      expect(mcpResponse('data: {"jsonrpc":"2.0",\ndata: "id":1,"result":{}}\n\n', 1)?.id).assertEqual(1);
      expect(mcpResponse('data: {"jsonrpc":', 1)).assertUndefined();
    });
    it('rejectsCredentialBearingAndUnencryptedMcpEndpoints', 0, () => {
      const data = defaultProductivity();
      data.servers = [{ id: 's', name: 'test', url: 'https://user:secret@example.com/mcp', enabled: true, credentialAlias: '' }];
      rejects(() => validateProductivity(data));
      data.servers[0].url = 'http://example.com/mcp'; rejects(() => validateProductivity(data));
      data.servers[0].url = 'https://example.com/mcp'; validateProductivity(data);
    });
  });
}
