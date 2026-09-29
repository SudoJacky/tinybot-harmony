import { describe, expect, it } from '@ohos/hypium';
import { ChatStream } from '../main/ets/services/ChatStream';
import { emptyData, MessageData, parseAppData, requestHistory } from '../main/ets/model/Conversation';
import { completionUrl } from '../main/ets/services/providers/ChatCompletionsProtocol';
import { threadWorkspacePath } from '../main/ets/model/Workspace';

const TEXT = 'data: {"choices":[{"index":0,"delta":{"content":"你好，Tinybot 🌱"},"finish_reason":null}]}\r\n\r\n';
const STOP = 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n';
const DONE = 'data: [DONE]\n\n';

function rejects(action: () => void, fragment: string): void {
  let message = '';
  try {
    action();
  } catch (error) {
    message = (error as Error).message;
  }
  expect(message.includes(fragment)).assertTrue();
}

function message(id: string, role: string, status: string, content: string): MessageData {
  return { id: id, role: role, status: status, content: content, error: '' };
}

export default function coreTests(): void {
  describe('Workspace', () => {
    it('rejectsIdsThatCouldEscapeOrAliasAnotherDirectory', 0, () => {
      const invalid = ['', '.', '..', '../other', 'a/../../other', '/absolute', 'a\\b', 'a.b', '%2e%2e', 'a\u0000b', 'a'.repeat(129)];
      invalid.forEach((id: string) => rejects(() => { threadWorkspacePath('/files/workspace', id); }, '会话 ID'));
    });
    it('restoresStableWorkspaceIdentityWithoutPersistingAbsolutePaths', 0, () => {
      const data = emptyData();
      data.threads = [{ id: 'a85c2c71-64ae-4c62-b51f-f47927e1cd34', title: '工作区', updatedAt: 1, messages: [] }];
      data.activeThreadId = data.threads[0].id;
      const restored = parseAppData(JSON.stringify(data));
      const threadId = restored.threads[0].id;
      expect(threadWorkspacePath('/files/workspace', threadId)).assertEqual('/files/workspace/' + data.activeThreadId);
      expect(threadWorkspacePath('/restored/files/workspace', threadId)).assertEqual('/restored/files/workspace/' + data.activeThreadId);
    });
    it('rejectsUnsafeIdsRestoredFromLegacyConversationData', 0, () => {
      const data = emptyData();
      data.threads = [{ id: '../tinybot-v1.json', title: '旧会话', updatedAt: 1, messages: [] }];
      const restored = parseAppData(JSON.stringify(data));
      rejects(() => { threadWorkspacePath('/files/workspace', restored.threads[0].id); }, '会话 ID');
    });
  });

  describe('ChatStream', () => {
    it('streamsChineseAcrossEveryCharacterBoundary', 0, () => {
      const wire = ': heartbeat\r\n\r\n' + TEXT + STOP + DONE;
      for (let boundary = 1; boundary < wire.length; boundary++) {
        let output = '';
        const stream = new ChatStream((text: string) => { output += text; });
        stream.push(wire.slice(0, boundary));
        stream.push(wire.slice(boundary));
        stream.finish();
        expect(output).assertEqual('你好，Tinybot 🌱');
      }
    });
    it('publishesBeforeCompletion', 0, () => {
      let output = '';
      const stream = new ChatStream((text: string) => { output += text; });
      stream.push(TEXT);
      expect(output).assertEqual('你好，Tinybot 🌱');
      stream.push(STOP + DONE);
      stream.finish();
    });
    it('acceptsTrailingUsageAndRoleOnlyChunks', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push('data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}\n\n');
      stream.push(TEXT + STOP + 'data: {"choices":[],"usage":{"total_tokens":20}}\n\n' + DONE);
      stream.finish();
    });
    it('supportsMultilineSseEvents', 0, () => {
      let output = '';
      const stream = new ChatStream((text: string) => { output += text; });
      stream.push('data: {"choices":\n' + 'data: [{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n' + DONE);
      stream.finish();
      expect(output).assertEqual('ok');
    });
    it('rejectsConnectionLossWithPartialText', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push(TEXT);
      rejects(() => stream.finish(), '结束标记');
    });
    it('requiresFinishReasonEvenWithDone', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push(TEXT + DONE);
      rejects(() => stream.finish(), '结束标记');
    });
    it('reportsTruncation', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push(TEXT + STOP.replace('stop', 'length') + DONE);
      rejects(() => stream.finish(), '输出上限');
    });
    it('reportsFiltering', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push(TEXT + STOP.replace('stop', 'content_filter') + DONE);
      rejects(() => stream.finish(), '内容过滤');
    });
    it('rejectsUnadvertisedToolCalls', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push(STOP.replace('stop', 'tool_calls') + DONE);
      rejects(() => stream.finish(), '工具调用');
    });
    it('rejectsMalformedJson', 0, () => {
      const stream = new ChatStream(() => {});
      rejects(() => stream.push('data: {broken}\n\n'), 'JSON');
    });
    it('rejectsProviderErrorsWithoutLeakingPayload', 0, () => {
      const stream = new ChatStream(() => {});
      rejects(() => stream.push('data: {"error":{"message":"sensitive upstream error"}}\n\n'), '模型服务');
    });
    it('rejectsEmptyCompletions', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push(STOP + DONE);
      rejects(() => stream.finish(), '没有返回');
    });
    it('rejectsContentAfterStop', 0, () => {
      const stream = new ChatStream(() => {});
      stream.push(TEXT + STOP);
      rejects(() => stream.push(TEXT), '继续返回文本');
    });
  });

  describe('Conversation', () => {
    it('normalizesEndpointWithoutDuplicatingPath', 0, () => {
      expect(completionUrl(' https://example.com/v1/// ')).assertEqual('https://example.com/v1/chat/completions');
      expect(completionUrl('https://example.com/chat/completions')).assertEqual('https://example.com/chat/completions');
    });
    it('rejectsUnsafeOrAmbiguousEndpoints', 0, () => {
      const invalid = ['http://example.com', 'https://user:secret@example.com', 'https://example.com?a=b', 'https://example.com/#key'];
      invalid.forEach((url: string) => rejects(() => { completionUrl(url); }, 'HTTPS'));
    });
    it('onlyReplaysCompleteTurnsAndCurrentPrompt', 0, () => {
      const messages: MessageData[] = [
        message('1', 'user', 'complete', 'old'), message('2', 'assistant', 'complete', 'answer'),
        message('3', 'user', 'complete', 'failed prompt'), message('4', 'assistant', 'failed', 'partial'),
        message('5', 'user', 'complete', 'stopped prompt'), message('6', 'assistant', 'stopped', 'partial'),
        message('7', 'user', 'complete', 'new')
      ];
      const history = requestHistory(messages, 'system');
      expect(history.length).assertEqual(4);
      expect(history[0].role).assertEqual('system');
      expect(history[2].content).assertEqual('answer');
      expect(history[3].content).assertEqual('new');
    });
    it('recoversInterruptedTurnsWithoutFabricatingCompletion', 0, () => {
      const data = emptyData();
      data.threads = [{ id: 'thread', title: '问题', updatedAt: 10, messages: [
        message('u', 'user', 'complete', '问题'), message('a', 'assistant', 'generating', '部分回答')
      ] }];
      data.activeThreadId = 'thread';
      const restored = parseAppData(JSON.stringify(data));
      expect(restored.threads[0].messages[1].status).assertEqual('stopped');
      expect(restored.threads[0].messages[1].content).assertEqual('部分回答');
    });
    it('rejectsUnknownVersions', 0, () => {
      const data = emptyData();
      data.version = 99;
      rejects(() => { parseAppData(JSON.stringify(data)); }, '格式不受支持');
    });
    it('rejectsDuplicateThreadIds', 0, () => {
      const data = emptyData();
      data.threads = [
        { id: 'duplicate', title: 'a', updatedAt: 1, messages: [] },
        { id: 'duplicate', title: 'b', updatedAt: 2, messages: [] }
      ];
      rejects(() => { parseAppData(JSON.stringify(data)); }, '会话数据损坏');
    });
    it('rejectsInvalidMessageOrder', 0, () => {
      const data = emptyData();
      data.threads = [{ id: 't', title: 'a', updatedAt: 1, messages: [
        message('a', 'assistant', 'complete', 'wrong'), message('b', 'user', 'complete', 'wrong')
      ] }];
      rejects(() => { parseAppData(JSON.stringify(data)); }, '消息数据损坏');
    });
    it('rejectsDanglingActiveThread', 0, () => {
      const data = emptyData();
      data.activeThreadId = 'missing';
      rejects(() => { parseAppData(JSON.stringify(data)); }, '找不到');
    });
  });
}
