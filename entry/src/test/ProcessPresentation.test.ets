import { describe, expect, it } from '@ohos/hypium';
import { AgentStep, ToolExecution } from '../main/ets/model/Agent';
import { setLocale } from '../main/ets/model/I18n';
import { buildTimeline, describeTools, durationLabel, elapsedMs, foldsToAnswer, persistentTool, summarizeProcess,
  thoughtTail } from '../main/ets/model/ProcessPresentation';
import { toolStat } from '../main/ets/model/ToolPresentation';
import { RequestUsage } from '../main/ets/model/Usage';

function tool(id: string, status: string = 'complete', name: string = 'read_file', output: string = '', args: string = '{}'): ToolExecution {
  return { call: { id: id, type: 'function', function: { name: name, arguments: args } }, status: status, output: output };
}

function usage(startedAt: number, durationMs: number): RequestUsage {
  return { id: '', provider: '', model: '', startedAt: startedAt, durationMs: durationMs, status: 'complete' };
}

export default function processPresentationTests(): void {
  describe('ProcessPresentation', () => {
    it('groupsEverythingBetweenTwoNarrationsWithTheNextStepsThinking', 0, () => {
      const steps: AgentStep[] = [
        { content: '', reasoningContent: 'plan', tools: [tool('a')] },
        { content: '', tools: [tool('b')] },
        { content: 'found it', reasoningContent: 'look closer', tools: [tool('c', 'running')] }];
      const timeline = buildTimeline(steps);
      expect(timeline.map((entry) => entry.kind).join(',')).assertEqual('process,text,process');
      // Thought of step 2 happened before its narration, so it closes the first group.
      expect(timeline[0].items.map((item) => item.step + ':' + item.tool).join(',')).assertEqual('0:-1,0:0,1:0,2:-1');
      expect(timeline[1].step).assertEqual(2);
      expect(timeline[2].items.map((item) => item.step + ':' + item.tool).join(',')).assertEqual('2:0');
    });
    it('keepsGroupKeysStableWhileTheRunGrowsAndBreaksGroupsAtSteering', 0, () => {
      const steps: AgentStep[] = [{ content: 'start', tools: [tool('a')] }];
      const key = buildTimeline(steps)[1].key;
      steps.push({ content: '', reasoningContent: 'more', tools: [tool('b')] });
      expect(buildTimeline(steps)[1].key).assertEqual(key);
      expect(buildTimeline(steps)[1].items.length).assertEqual(3);
      steps.push({ content: '', tools: [tool('c')], steering: { id: 's', text: 'also check tests', mode: 'steer' } });
      expect(buildTimeline(steps).map((entry) => entry.kind).join(',')).assertEqual('text,process,steering,process');
      expect(buildTimeline([]).length).assertEqual(0);
    });
    it('foldsOnlyAnswersThatEndInNarrationAfterSomeProcess', 0, () => {
      expect(foldsToAnswer(buildTimeline([{ content: 'hi', tools: [] }]))).assertFalse();
      expect(foldsToAnswer(buildTimeline([{ content: 'hi', reasoningContent: 'hmm', tools: [] }]))).assertTrue();
      expect(foldsToAnswer(buildTimeline([{ content: 'reading', tools: [tool('a')] }]))).assertFalse();
      expect(foldsToAnswer(buildTimeline([{ content: '', tools: [tool('a')] }, { content: 'done', tools: [] }]))).assertTrue();
    });
    it('countsFailuresAndKeepsChartsAndResumeActionsInTheTranscript', 0, () => {
      const plan = '{"steps":[{"step":"work","status":"completed"}]}';
      const first = tool('first', 'complete', 'update_plan', plan);
      const latest = tool('latest', 'complete', 'update_plan', plan);
      const broken = tool('broken', 'complete', 'update_plan', '{}');
      const steps: AgentStep[] = [{ content: '', tools: [first, latest, broken, tool('x', 'failed')] }, { content: 'done', tools: [] }];
      const summary = summarizeProcess(steps);
      expect(summary.failures).assertEqual(1);
      expect(summary.operations).assertEqual(4);
      expect(persistentTool(first)).assertFalse();
      expect(persistentTool(latest)).assertFalse();
      expect(persistentTool(tool('chart', 'complete', 'publish_data_view'))).assertTrue();
      expect(persistentTool(tool('form', 'interrupted', 'request_user_input'))).assertTrue();
      expect(persistentTool(tool('form', 'cancelled', 'request_user_input'))).assertTrue();
      expect(persistentTool(tool('ordinary'))).assertFalse();
    });
    it('describesAGroupAsASentenceCountingEachFileOnce', 0, () => {
      setLocale('zh-CN');
      const tools = [tool('a', 'complete', 'edit_file', '', '{"path":"a.ets"}'), tool('b', 'complete', 'edit_file', '', '{"path":"a.ets"}'),
        tool('c', 'complete', 'read_file', '', '{"path":"b.ets"}'), tool('d', 'complete', 'read_file', '', '{"path":"c.ets"}')];
      expect(describeTools(tools)).assertEqual('编辑了 1 个文件，读取了 2 个文件');
      setLocale('en');
      expect(describeTools(tools)).assertEqual('Edited 1 file(s) · Read 2 file(s)');
      setLocale('zh-CN');
    });
    it('summarizesElapsedTimeThoughtTailAndToolResults', 0, () => {
      setLocale('zh-CN');
      expect(elapsedMs([{ content: '', tools: [], usage: usage(1000, 2000) }, { content: '', tools: [], usage: usage(10000, 5000) }]))
        .assertEqual(14000);
      expect(elapsedMs([{ content: '', tools: [] }])).assertEqual(0);
      expect(durationLabel(14000)).assertEqual('14 秒');
      expect(durationLabel(602000)).assertEqual('10 分 2 秒');
      expect(thoughtTail('first\n\nsecond line  ')).assertEqual('second line');
      expect(thoughtTail('abcdefghij', 4)).assertEqual('…ghij');
      expect(toolStat('edit_file', '{"oldText":"a","newText":"a\\nb\\nc"}', '{}', 'complete')).assertEqual('+3 −1');
      expect(toolStat('search_file_content', '{}', '{"matches":[{},{}]}', 'complete')).assertEqual('2 处匹配');
      expect(toolStat('read_file', '{}', '{"content":"x\\ny"}', 'failed')).assertEqual('');
    });
  });
}
