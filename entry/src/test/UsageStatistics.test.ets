import { describe, expect, it } from '@ohos/hypium';
import { RequestUsage, UsageStream } from '../main/ets/model/Usage';
import { summarizeUsage, usageDate } from '../main/ets/model/UsageStatistics';
import { attributeLegacyUsage } from '../main/ets/model/UsageAttribution';
import { ThreadData } from '../main/ets/model/Conversation';
import { UsageQuery } from '../main/ets/model/UsageQuery';
import { UsageFilter } from '../main/ets/model/UsageStatistics';

function request(id: string, time: number, provider: string = 'one', model: string = 'model'): RequestUsage {
  return { id: id, provider: provider, model: model, startedAt: time, durationMs: 1000, status: 'complete', tokens: { input: 100, output: 20 } };
}

export default function usageStatisticsTests(): void {
  describe('UsageStatistics', () => {
    const now = new Date(2026, 0, 3, 12).getTime();
    it('queriesBoundedPagesWithStableTimestampTiesAndLazyTurns', 0, async () => {
      const items: RequestUsage[] = [];
      for (let index = 0; index < 97; index++) {
        const item = request(String(index).padStart(3, '0'), now);
        item.origin = { threadId: 'thread', turnId: 'turn' }; items.push(item);
      }
      const query = new UsageQuery(items.reverse());
      const filter: UsageFilter = { range: 3, provider: '', model: '', threadId: '', now: now };
      const summary = await query.summary(filter);
      expect(summary.totals.total).assertEqual(97 * 120); expect(summary.records.length).assertEqual(0);
      expect(summary.sessions[0].turns.length).assertEqual(0); expect(summary.sessions[0].records.length).assertEqual(0);
      const first = await query.page(filter); const second = await query.page(filter, first.next);
      expect(first.records.length).assertEqual(30); expect(first.records[29].id).assertEqual('029');
      expect(second.records[0].id).assertEqual('030'); expect(second.records.length).assertEqual(30);
      const turns = await query.turns(filter, 'thread'); expect(turns.length).assertEqual(1);
      expect(turns[0].calls).assertEqual(97); expect(turns[0].records.length).assertEqual(0);
      expect((await query.page(filter, undefined, 'thread', 'absent')).records.length).assertEqual(0);
    });
    it('cancelledUsageQueriesCannotPublishStaleResults', 0, async () => {
      const query = new UsageQuery([request('one', now)]);
      const pending = query.summary({ range: 3, provider: '', model: '', threadId: '', now: now }); query.cancel();
      let rejected = false;
      try { await pending; } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('groupsManyCallsPerTurnAndKeepsBackgroundAndTeamUsage', 0, () => {
      const items = ['conversation', 'conversation', 'team_task', 'title', 'memory', 'compaction'].map((purpose: string, index: number): RequestUsage => {
        const item = request('call-' + index, now - index); item.origin = { threadId: 'one', turnId: 'turn', purpose: purpose }; return item;
      });
      const missing = request('missing', now); missing.tokens = undefined; missing.status = 'failed';
      missing.origin = { threadId: 'one', turnId: 'turn', purpose: 'conversation' }; items.push(missing);
      const second = request('second-turn', now); second.origin = { threadId: 'one', turnId: 'turn-two', purpose: 'conversation' }; items.push(second);
      items.push(request('legacy', now));
      const stats = summarizeUsage(items, 2, '', '', now);
      expect(stats.totals.total).assertEqual(960); expect(stats.sessions.length).assertEqual(2);
      expect(stats.sessions[0].total).assertEqual(840); expect(stats.sessions[0].turns.length).assertEqual(2);
      expect(stats.sessions[0].turns.find((turn) => turn.key === 'turn')?.calls).assertEqual(7);
      expect(stats.purposes.find((group) => group.key === 'team_task')?.total).assertEqual(120);
      expect(summarizeUsage(items, 2, '', '', now, 'one').totals.calls).assertEqual(8);
      expect(summarizeUsage(items, 2, '', '', now, 'unassigned').totals.calls).assertEqual(1);
      expect(stats.weeks.reduce((sum, week) => sum + week.total, 0)).assertEqual(stats.totals.total);
    });
    it('activityUsesCountsAndDeduplicatesSkillPerTurnWithoutExtraTokens', 0, () => {
      const one = request('one', now); one.origin = { threadId: 'thread', turnId: 'turn', skill: 'analysis' };
      one.tools = [{ id: 'tool', name: 'read_skill', skill: 'analysis', status: 'complete', startedAt: now, durationMs: 30 }];
      const two = request('two', now); two.origin = { threadId: 'thread', turnId: 'turn', skill: 'analysis' };
      two.tools = [{ id: 'tool2', name: 'mcp_call', server: 'server', remoteTool: 'search', status: 'failed', startedAt: now, durationMs: 40 }];
      const stats = summarizeUsage([one, two], 2, '', '', now);
      expect(stats.totals.total).assertEqual(240); expect(stats.skills[0].calls).assertEqual(1);
      expect(stats.tools.reduce((sum, item) => sum + item.calls, 0)).assertEqual(2);
      expect(stats.tools.find((item) => item.label === 'server / search')?.failed).assertEqual(1);
    });
    it('legacyJoinRequiresUniqueLedgerIdAndNeverAddsTranscriptCopies', 0, () => {
      const item = request('legacy', now);
      const thread: ThreadData = { id: 'original', title: 'Original', updatedAt: now, messages: [
        { id: 'user', role: 'user', content: 'Question', status: 'complete', error: '' },
        { id: 'assistant', role: 'assistant', content: 'Answer', status: 'complete', error: '', steps: [{ content: 'Answer', tools: [], usage: item }] }
      ] };
      const joined = attributeLegacyUsage([item, request('orphan', now)], [thread]);
      expect(joined.length).assertEqual(2); expect(joined[0].origin?.threadId).assertEqual('original');
      expect(joined[0].origin?.turnId).assertEqual('user'); expect(item.origin === undefined).assertTrue();
      const branch = JSON.parse(JSON.stringify(thread)) as ThreadData; branch.id = 'branch';
      expect(attributeLegacyUsage([item], [thread, branch])[0].origin === undefined).assertTrue();
      item.origin = { threadId: 'original', turnId: 'user' };
      expect(attributeLegacyUsage([item], [branch])[0].origin?.threadId).assertEqual('original');
    });
    it('cacheAndReasoningAreSubsetsAndFailedRequestsKeepReportedUsage', 0, () => {
      const item = request('one', now); item.tokens = { input: 100, output: 20, cached: 70, cacheWrite: 10, reasoning: 5 }; item.status = 'failed';
      const total = summarizeUsage([item], 2, '', '', now).totals;
      expect(total.total).assertEqual(120); expect(total.failed).assertEqual(1);
      expect(total.cached).assertEqual(70); expect(total.reasoning).assertEqual(5); expect(total.cacheWrite).assertEqual(10);
    });
    it('distinguishesMissingAndZeroAndPartialDetails', 0, () => {
      const missing = request('missing', now); missing.tokens = undefined; missing.status = 'running_or_unknown';
      const zero = request('zero', now); zero.tokens = { input: 0, output: 0, cached: 0 }; zero.status = 'cancelled';
      const invalid = request('invalid', now); invalid.tokens = { input: -1, output: 3 };
      const total = summarizeUsage([missing, zero, invalid], 2, '', '', now).totals;
      expect(total.calls).assertEqual(3); expect(total.reported).assertEqual(1); expect(total.missing).assertEqual(2);
      expect(total.cachedReports).assertEqual(1); expect(total.reasoningReports).assertEqual(0);
      expect(total.total).assertEqual(0); expect(total.pending).assertEqual(1); expect(total.cancelled).assertEqual(1);
    });
    it('usesInclusiveLocalMidnightAcrossYearBoundaryAndFillsEmptyDays', 0, () => {
      const start = new Date(2025, 11, 28).getTime();
      const stats = summarizeUsage([request('before', start - 1), request('start', start), request('today', now), request('future', now + 1)], 1, '', '', now);
      expect(stats.records.length).assertEqual(2); expect(stats.records[0].id).assertEqual('today');
      expect(stats.days.length).assertEqual(7); expect(stats.days[0].date).assertEqual('2025-12-28');
      expect(stats.days[1].calls).assertEqual(0); expect(stats.days[6].date).assertEqual('2026-01-03');
      expect(stats.days[0].total).assertEqual(120); expect(stats.peak).assertEqual(120);
    });
    it('todayExcludesYesterdayAndAllTimeRetainsOlderTotals', 0, () => {
      const records = [request('old', new Date(2025, 0, 1).getTime()), request('yesterday', new Date(2026, 0, 2, 23, 59).getTime()), request('today', now)];
      expect(summarizeUsage(records, 0, '', '', now).totals.calls).assertEqual(1);
      const all = summarizeUsage(records, 3, '', '', now);
      expect(all.totals.calls).assertEqual(3); expect(all.days.length).assertEqual(30);
      expect(all.days.reduce((sum, day) => sum + day.calls, 0)).assertEqual(2);
    });
    it('filtersExactProviderAndModelAndDoesNotMergeSameModelAcrossProviders', 0, () => {
      const records = [request('one', now, 'one', 'shared'), request('two', now, 'two', 'shared'), request('three', now, 'one', 'different')];
      const stats = summarizeUsage(records, 2, '', 'shared', now);
      expect(stats.models.length).assertEqual(2); expect(stats.totals.total).assertEqual(240);
      expect(summarizeUsage(records, 2, 'one', 'shared', now).records.length).assertEqual(1);
      expect(summarizeUsage(records, 2, 'on', '', now).records.length).assertEqual(0);
      expect(records[0].id).assertEqual('one');
    });
    it('aggregatesAnthropicCacheWithoutCountingItTwice', 0, () => {
      const stream = new UsageStream();
      stream.push('data: {"message":{"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":90,"cache_creation_input_tokens":20}}}\n\n');
      stream.push('data: {"usage":{"output_tokens":30}}\n\n');
      const item = request('anthropic', now); item.tokens = stream.result();
      const stats = summarizeUsage([item], 0, '', '', now);
      expect(stats.totals.input).assertEqual(120); expect(stats.totals.total).assertEqual(150);
      expect(stats.days[0].date).assertEqual(usageDate(now));
    });
    it('emptyFiltersHaveZeroTotalsAndStableChartScale', 0, () => {
      const stats = summarizeUsage([], 2, '', '', now);
      expect(stats.totals.total).assertEqual(0); expect(stats.models.length).assertEqual(0);
      expect(stats.days.length).assertEqual(30); expect(stats.peak).assertEqual(1);
    });
  });
}
