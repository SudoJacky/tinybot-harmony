import { describe, expect, it } from '@ohos/hypium';
import { ThreadData, requestHistory } from '../main/ets/model/Conversation';
import { captureThreadReference, isCompactCommand, referenceQuery, removeReferenceQuery, validateThreadReferences } from '../main/ets/model/ThreadReferences';

export default function threadReferenceTests(): void {
  describe('ThreadReferences', () => {
    it('snapshotIncludesCompleteTextWithoutReasoningOrNestedReferences', 0, () => {
      const source: ThreadData = { id: 'source', title: 'A chat', updatedAt: 0, messages: [
        { id: 'u', role: 'user', content: 'question', status: 'complete', error: '', references: [
          { threadId: 'nested', title: 'nested', content: 'nested secret', capturedAt: 0, truncated: false }] },
        { id: 'a', role: 'assistant', content: 'answer', status: 'complete', error: '',
          steps: [{ content: 'answer', reasoningContent: 'private reasoning', tools: [] }] },
        { id: 'u2', role: 'user', content: 'unfinished question', status: 'complete', error: '' },
        { id: 'a2', role: 'assistant', content: 'unfinished answer', status: 'stopped', error: '' }
      ] };
      const ref = captureThreadReference(source); validateThreadReferences([ref]);
      expect(ref.content).assertEqual('用户：question\n助手：answer');
      source.messages[1].content = 'edited'; expect(ref.content.includes('edited')).assertFalse();
      const history = requestHistory([{ id: 'current', role: 'user', content: 'compare', status: 'complete', error: '', references: [ref] }], 'system');
      expect(history[0].content).assertEqual('system');
      expect(history[1].content.includes('question')).assertTrue();
      expect(history[1].role).assertEqual('user');
    });
    it('longReferencesAreBoundedAndKeepRecentText', 0, () => {
      const source: ThreadData = { id: 'source', title: 'Long', updatedAt: 0, messages: [
        { id: 'u', role: 'user', content: 'old question', status: 'complete', error: '' },
        { id: 'a', role: 'assistant', content: 'x'.repeat(10000) + 'recent ending', status: 'complete', error: '' }
      ] };
      const ref = captureThreadReference(source); validateThreadReferences([ref]);
      expect(ref.truncated).assertTrue(); expect(ref.content.length <= 8000).assertTrue();
      expect(ref.content.endsWith('recent ending')).assertTrue();
      let duplicateRejected = false;
      try { validateThreadReferences([ref, ref]); } catch (_) { duplicateRejected = true; }
      expect(duplicateRejected).assertTrue();
    });
    it('commandAndMentionParsingDoNotConsumeOrdinaryTextOrEmail', 0, () => {
      expect(isCompactCommand(' /COMPACT \n')).assertTrue();
      expect(isCompactCommand('/compact later')).assertFalse(); expect(isCompactCommand('explain /compact')).assertFalse();
      expect(referenceQuery('compare @release plan')).assertEqual('release plan');
      expect(referenceQuery('name@example.com') === undefined).assertTrue();
      expect(removeReferenceQuery('compare @release plan')).assertEqual('compare ');
      expect(removeReferenceQuery('unchanged')).assertEqual('unchanged');
    });
  });
}
